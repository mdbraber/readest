import { useCallback, useEffect, useRef } from 'react';
import { useAuth } from '@/context/AuthContext';
import { useSync } from '@/hooks/useSync';
import { useSyncContext } from '@/context/SyncContext';
import { BookConfig, FIXED_LAYOUT_FORMATS } from '@/types/book';
import { DBBookConfig } from '@/types/records';
import { useBookDataStore } from '@/store/bookDataStore';
import { useLibraryStore } from '@/store/libraryStore';
import { useReaderStore } from '@/store/readerStore';
import { useSettingsStore } from '@/store/settingsStore';
import { useTranslation } from '@/hooks/useTranslation';
import { serializeConfig } from '@/utils/serializer';
import { transformBookConfigFromDB } from '@/utils/transform';
import { CFI } from '@/libs/document';
import { debounce } from '@/utils/debounce';
import { eventDispatcher } from '@/utils/event';
import { DEFAULT_BOOK_SEARCH_CONFIG, SYNC_PROGRESS_INTERVAL_SEC } from '@/services/constants';
import { getCFIFromXPointer, getXPointerFromCFI } from '@/utils/xcfi';
import { useWindowActiveChanged } from './useWindowActiveChanged';

export const useProgressSync = (bookKey: string) => {
  const _ = useTranslation();
  const { getConfig, setConfig, getBookData } = useBookDataStore();
  const { getView, getProgress, setHoveredBookKey } = useReaderStore();
  const { settings } = useSettingsStore();
  const { syncedConfigs, syncConfigs, syncBooks } = useSync(bookKey);
  const { syncClient } = useSyncContext();
  const { user } = useAuth();
  const progress = getProgress(bookKey);

  const configPulled = useRef(false);
  const hasPulledConfigOnce = useRef(false);
  // Captured at first hook-run, BEFORE any saveConfig has bumped state.
  // true = no real reading position on this device yet (fresh PWA install,
  // never opened here, etc.) — server should win unconditionally.
  const initialFreshness = useRef<boolean | null>(null);
  // The progressUpdatedAt we KNOW the server has. Updated when:
  //   (a) initial-open pull processes server data
  //   (b) flip-sync applies server data (server-wins branch)
  //   (c) flip-sync pushes local data (local-wins branch)
  // Compared against fresh server timestamps on every flip — NOT against
  // local config.progressUpdatedAt, because that gets bumped to NOW by
  // useProgressAutoSave on every flip and would defeat the pull-on-flip
  // semantics ("local is always newer").
  const lastSyncedProgressTs = useRef<number>(0);

  const pushConfig = async (bookKey: string, config: BookConfig | null) => {
    const book = getBookData(bookKey)?.book;
    if (!config || !book || !user) return;
    const bookHash = bookKey.split('-')[0]!;
    const metaHash = book.metaHash;
    const newConfig = { ...config, bookHash, metaHash };
    const compressedConfig = JSON.parse(
      serializeConfig(newConfig, settings.globalViewSettings, DEFAULT_BOOK_SEARCH_CONFIG),
    );
    delete compressedConfig.booknotes;
    console.log("[sync-push] pushing config", {
      bookHash,
      progressUpdatedAt: compressedConfig.progressUpdatedAt,
      updatedAt: compressedConfig.updatedAt,
      progress: compressedConfig.progress,
      location: compressedConfig.location,
    });
    await syncConfigs([compressedConfig], bookHash, metaHash, 'push');

    // Remember what we just pushed so future flips know the server's state.
    lastSyncedProgressTs.current =
      config.progressUpdatedAt ?? config.updatedAt ?? lastSyncedProgressTs.current;

    // Also push the corresponding `books` row. The library sync lane
    // (useBooksSync) only runs while the library page is mounted, so while a
    // reader stays open the server's `books` record is never re-pushed and
    // other devices' library pull-to-refresh keeps showing stale progress
    // (issue #4198). useProgressAutoSave has already merged config.progress
    // into the in-memory library Book via saveConfig, so we just forward
    // that book through the books lane.
    const libraryBook = useLibraryStore.getState().library.find((b) => b.hash === bookHash);
    if (libraryBook && !libraryBook.deletedAt) {
      await syncBooks([libraryBook], 'push');
    }
  };

  const pullConfig = async (bookKey: string) => {
    const book = getBookData(bookKey)?.book;
    if (!user || !book) return;
    const bookHash = bookKey.split('-')[0]!;
    const metaHash = book.metaHash;
    await syncConfigs([], bookHash, metaHash, 'pull');
  };

  // Apply a single remote config to local state and view. Returns the
  // applied server progressUpdatedAt so the caller can update lastSyncedProgressTs.
  // If view isn't ready yet (book still loading), retries up to ~3s.
  const applyServerConfig = async (syncedConfig: BookConfig): Promise<number> => {
    const config = getConfig(bookKey);
    if (!config) return 0;

    const configCFI = config?.location;
    let remoteCFILocation = syncedConfig.location;
    const xpointer = syncedConfig.xpointer;
    const bookData = getBookData(bookKey);

    // Update local config immediately so future events see server's data
    const filteredSyncedConfig = Object.fromEntries(
      Object.entries(syncedConfig).filter(([_, value]) => value !== null && value !== undefined),
    );
    setConfig(bookKey, { ...config, ...filteredSyncedConfig });

    // Try to resolve xpointer to CFI if view+bookDoc available now
    const earlyView = getView(bookKey);
    if (xpointer && earlyView && bookData && bookData.bookDoc) {
      try {
        const pContents = earlyView.renderer.getContents();
        const pIdx = earlyView.renderer.primaryIndex;
        const content = pContents.find((x) => x.index === pIdx) ?? pContents[0];
        const candidateCFI = await getCFIFromXPointer(
          xpointer,
          content?.doc,
          content?.index,
          bookData.bookDoc,
        );
        if (!remoteCFILocation || CFI.compare(remoteCFILocation, candidateCFI) < 0) {
          remoteCFILocation = candidateCFI;
        }
      } catch (error) {
        console.warn('[sync] Remote XPointer unresolvable; falling back to CFI', error);
      }
    }

    const samePosition =
      configCFI && remoteCFILocation && CFI.compare(configCFI, remoteCFILocation) === 0;
    if (samePosition) {
      // Already at this position — counts as applied.
      return syncedConfig.progressUpdatedAt ?? syncedConfig.updatedAt ?? 0;
    }
    if (!remoteCFILocation) {
      // Couldn't resolve a navigable position (e.g. xpointer conversion failed).
      // Do not advance the watermark so the next sync will retry.
      return 0;
    }

    const isPreview = useReaderStore.getState().getViewState(bookKey)?.previewMode;
    if (isPreview) {
      return syncedConfig.progressUpdatedAt ?? syncedConfig.updatedAt ?? 0;
    }

    // Retry view.goTo until view is available (book may still be loading)
    const targetCFI = remoteCFILocation;
    const tryGoTo = (attempt = 0): void => {
      const view = getView(bookKey);
      if (view) {
        console.log('[sync] Applying server position to view', {
          configCFI,
          remoteCFILocation: targetCFI,
          attempt,
        });
        view.goTo(targetCFI);
        setHoveredBookKey(null);
        eventDispatcher.dispatch('hint', {
          bookKey,
          message: _('Reading Progress Synced'),
        });
        return;
      }
      if (attempt >= 100) {
        console.warn('[sync] view never became ready; giving up on goTo', { targetCFI });
        return;
      }
      setTimeout(() => tryGoTo(attempt + 1), 100);
    };
    tryGoTo();

    return syncedConfig.progressUpdatedAt ?? syncedConfig.updatedAt ?? 0;
  };

  // Per-flip / per-chapter-jump sync. Pull fresh server state, decide who
  // wins by comparing serverProgTs against lastSyncedProgressTs.current.
  //   - server > lastSeen  → apply server position (server moved while we read)
  //   - else               → push local position
  const syncOnPositionChange = async () => {
    if (!user) return;
    const book = getBookData(bookKey)?.book;
    const config = getConfig(bookKey);
    const view = getView(bookKey);
    if (!config || !book || !view) return;
    if (useReaderStore.getState().getViewState(bookKey)?.previewMode) return;
    if (!config.progress || config.progress[0] === 0) return;

    const bookHash = bookKey.split('-')[0]!;
    const metaHash = book.metaHash;

    // Pull fresh server state for this specific book
    let serverConfig: BookConfig | undefined;
    try {
      const result = await syncClient.pullChanges(0, 'configs', bookHash, metaHash);
      const dbConfigs = (result.configs ?? []) as unknown as DBBookConfig[];
      const transformed = dbConfigs.map((c) => transformBookConfigFromDB(c));
      serverConfig = transformed.find(
        (c) => c.bookHash === bookHash || c.metaHash === metaHash,
      );
    } catch (err) {
      console.warn('[sync] pull-on-flip failed; falling through to push', err);
    }

    if (serverConfig) {
      const serverProgTs =
        serverConfig.progressUpdatedAt ?? serverConfig.updatedAt ?? 0;
      const lastSeen = lastSyncedProgressTs.current;
      const serverIsNewer = serverProgTs > lastSeen;
      console.log('[sync] flip-sync decision', {
        serverProgTs,
        lastSeen,
        action: serverIsNewer ? 'apply-server' : 'push-local',
      });
      if (serverIsNewer) {
        const appliedTs = await applyServerConfig(serverConfig);
        lastSyncedProgressTs.current = appliedTs;
        return;
      }
    }

    // Local is the source of truth → enrich CFI → xpointer and push.
    try {
      const contents = view.renderer.getContents();
      const primaryIndex = view.renderer.primaryIndex;
      const content = contents.find((x) => x.index === primaryIndex) ?? contents[0];
      if (content && !FIXED_LAYOUT_FORMATS.has(book.format)) {
        const { doc, index } = content;
        const xpointerResult = await getXPointerFromCFI(config.location!, doc, index || 0);
        config.xpointer = xpointerResult.xpointer;
      }
    } catch (error) {
      console.warn('[sync] Failed to convert CFI to XPointer', error);
    }
    await pushConfig(bookKey, config);
  };

  const handleSyncBookProgress = async (event: CustomEvent) => {
    const { bookKey: syncBookKey } = event.detail;
    if (syncBookKey === bookKey) {
      configPulled.current = false;
      await pullConfig(bookKey);
    }
  };

  useEffect(() => {
    eventDispatcher.on('sync-book-progress', handleSyncBookProgress);
    return () => {
      eventDispatcher.off('sync-book-progress', handleSyncBookProgress);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [bookKey]);

  // eslint-disable-next-line react-hooks/exhaustive-deps
  const handleAutoSync = useCallback(
    debounce(() => {
      // While the initial-open pull hasn't completed, just keep trying it.
      // Once configPulled is true, every flip runs full pull-then-decide.
      if (configPulled.current) {
        syncOnPositionChange();
      } else {
        pullConfig(bookKey);
      }
    }, SYNC_PROGRESS_INTERVAL_SEC * 1000),
    [],
  );

  // Auto-sync on every position change (debounced)
  useEffect(() => {
    if (!progress?.location || !user) return;
    handleAutoSync();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [progress?.location]);

  // Sync on focus: when the window/tab is brought to the foreground, run the
  // same pull-then-decide as a flip so a position advanced on another device
  // (e.g. a Kindle) is caught up. Gated on the Sync-on-focus setting; the
  // shared 1s debounce in handleAutoSync collapses the focus+visibility burst
  // mobile webviews fire on a single foreground transition.
  useWindowActiveChanged((isActive) => {
    if (isActive && settings.syncOnFocus && user && progress?.location) {
      handleAutoSync();
    }
  });

  // Immediate initial pull when book opens. Capture initialFreshness here
  // SYNCHRONOUSLY before saveConfig can race in and bump progressUpdatedAt.
  useEffect(() => {
    if (!progress || hasPulledConfigOnce.current) return;
    hasPulledConfigOnce.current = true;
    const c = getConfig(bookKey);
    // Fresh = this device never recorded a real flip for this book. The
    // only reliable signal is the absence of progressUpdatedAt. The current
    // config.progress / config.location are unreliable because foliate's
    // initial setProgress already wrote a synthetic position into the store
    // before this useEffect ran (see readerStore.setProgress).
    initialFreshness.current = c ? !c.progressUpdatedAt : true;
    console.log('[sync] captured initial freshness', {
      bookKey,
      isFresh: initialFreshness.current,
      progressUpdatedAt: c?.progressUpdatedAt,
      location: c?.location,
      progress: c?.progress,
    });
    pullConfig(bookKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [progress]);

  // Process the initial-open pull result
  useEffect(() => {
    if (configPulled.current || !syncedConfigs) return;
    configPulled.current = true;

    const config = getConfig(bookKey);
    const book = getBookData(bookKey)?.book;
    if (!config || !book) {
      lastSyncedProgressTs.current = 0;
      return;
    }

    const bookHash = bookKey.split('-')[0]!;
    const metaHash = book.metaHash;
    const localProgTs = config.progressUpdatedAt ?? config.updatedAt ?? 0;
    const syncedConfig = syncedConfigs.find(
      (c) => c.bookHash === bookHash || c.metaHash === metaHash,
    );
    if (!syncedConfig) {
      // No server record for this book → server has whatever local has
      // (we will push on first flip).
      lastSyncedProgressTs.current = localProgTs;
      return;
    }

    const remoteProgTs =
      syncedConfig.progressUpdatedAt ?? syncedConfig.updatedAt ?? 0;

    // Use snapshot captured at hook init (before foliate's synthetic
    // initial setProgress could pollute). Fallback to current state if
    // somehow not captured yet.
    const localIsFresh =
      initialFreshness.current ?? !config.progressUpdatedAt;

    if (localIsFresh || remoteProgTs > localProgTs) {
      console.log('[sync] initial-pull: applying server position', {
        reason: localIsFresh ? 'fresh-local' : 'server-newer',
        localProgTs,
        remoteProgTs,
        localIsFresh,
      });
      applyServerConfig(syncedConfig)
        .then((appliedTs) => {
          lastSyncedProgressTs.current = appliedTs;
        })
        .catch((error) => {
          console.error('[sync] Failed to apply initial remote progress', error);
        });
    } else {
      console.log('[sync] initial-pull: local is up-to-date', {
        localProgTs,
        remoteProgTs,
      });
      lastSyncedProgressTs.current = Math.max(localProgTs, remoteProgTs);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [syncedConfigs]);
};
