import { create } from 'zustand';
import { SystemSettings } from '@/types/settings';
import { Book, BookConfig, BookNote } from '@/types/book';
import { EnvConfigType } from '@/services/environment';
import { AppService } from '@/types/system';
import { BookDoc } from '@/libs/document';
import { useLibraryStore } from './libraryStore';

const LIBRARY_SAVE_THROTTLE_MS = 2000;
let librarySaveTimeoutId: ReturnType<typeof setTimeout> | null = null;
let librarySaveAppService: AppService | null = null;

const scheduleLibrarySave = (appService: AppService) => {
  librarySaveAppService = appService;
  if (librarySaveTimeoutId !== null) return;
  librarySaveTimeoutId = setTimeout(() => {
    librarySaveTimeoutId = null;
    const svc = librarySaveAppService;
    if (!svc) return;
    const { library } = useLibraryStore.getState();
    svc.saveLibraryBooks(library).catch((err: unknown) => {
      console.warn('Throttled library save failed:', err);
    });
  }, LIBRARY_SAVE_THROTTLE_MS);
};

export const flushPendingLibrarySave = async () => {
  if (librarySaveTimeoutId == null || !librarySaveAppService) return;
  clearTimeout(librarySaveTimeoutId);
  librarySaveTimeoutId = null;
  const { library } = useLibraryStore.getState();
  await librarySaveAppService.saveLibraryBooks(library);
};

export interface BookData {
  /* Persistent data shared with different views of the same book */
  id: string;
  book: Book | null;
  file: File | null;
  config: BookConfig | null;
  bookDoc: BookDoc | null;
  isFixedLayout: boolean;
}

interface BookDataState {
  booksData: { [id: string]: BookData };
  getConfig: (key: string | null) => BookConfig | null;
  setConfig: (key: string, partialConfig: Partial<BookConfig>) => void;
  saveConfig: (
    envConfig: EnvConfigType,
    bookKey: string,
    config: BookConfig,
    settings: SystemSettings,
  ) => Promise<void>;
  updateBooknotes: (key: string, booknotes: BookNote[]) => BookConfig | undefined;
  getBookData: (keyOrId: string) => BookData | null;
  clearBookData: (keyOrId: string) => void;
}

// Tracks last-PERSISTED progress signature per book hash for saveConfig.
// We cannot compare to current store state because the caller has already
// mutated the store before invoking us — store-vs-store is always empty.
const lastPersistedProgressSig = new Map<string, string>();

const computeProgressSig = (c: Partial<BookConfig>): string =>
  JSON.stringify({
    progress: c.progress,
    location: c.location,
    xpointer: c.xpointer,
    rsvpPosition: c.rsvpPosition,
  });

export const useBookDataStore = create<BookDataState>((set, get) => ({
  booksData: {},
  getBookData: (keyOrId: string) => {
    const id = keyOrId.split('-')[0]!;
    return get().booksData[id] || null;
  },
  clearBookData: (keyOrId: string) => {
    const id = keyOrId.split('-')[0]!;
    set((state) => {
      const newBooksData = { ...state.booksData };
      delete newBooksData[id];
      return {
        booksData: newBooksData,
      };
    });
  },
  getConfig: (key: string | null) => {
    if (!key) return null;
    const id = key.split('-')[0]!;
    return get().booksData[id]?.config || null;
  },
  setConfig: (key: string, partialConfig: Partial<BookConfig>) => {
    set((state: BookDataState) => {
      const id = key.split('-')[0]!;
      const config = state.booksData[id]?.config;
      if (!config) {
        console.warn('No config found for book', id);
        return state;
      }
      return {
        booksData: {
          ...state.booksData,
          [id]: {
            ...state.booksData[id]!,
            config: { ...config, ...partialConfig },
          },
        },
      };
    });
  },
  saveConfig: async (
    envConfig: EnvConfigType,
    bookKey: string,
    config: BookConfig,
    settings: SystemSettings,
  ) => {
    const appService = await envConfig.getAppService();
    const { library, hashIndex, setLibrary } = useLibraryStore.getState();
    const hash = bookKey.split('-')[0]!;
    const idx = hashIndex.get(hash);
    if (idx === undefined) return;

    // Immutably move the book to the front of the library with updated
    // progress and timestamps. We do NOT mutate the existing book object or
    // the existing library array — Zustand subscribers see fresh references
    // and the visibleLibrary cache stays in sync via setLibrary's full update.
    const now = Date.now();
    const original = library[idx]!;
    const updatedBook: Book = {
      ...original,
      progress: config.progress,
      updatedAt: now,
      downloadedAt: original.downloadedAt || now,
    };
    const newLibrary = [updatedBook, ...library.slice(0, idx), ...library.slice(idx + 1)];
    setLibrary(newLibrary);

    // Detect a real reading-position change vs the last-PERSISTED state.
    // Cannot diff store-vs-store (always empty since caller already wrote
    // the new state). Instead keep a process-local sig map.
    const prevConfig = get().booksData[hash]?.config;
    const currentSig = computeProgressSig(config);
    const lastSig = lastPersistedProgressSig.get(hash);
    const positionChanged = lastSig === undefined || lastSig !== currentSig;
    const nextProgressUpdatedAt = positionChanged
      ? now
      : (config.progressUpdatedAt ?? prevConfig?.progressUpdatedAt ?? now);
    if (positionChanged) {
      lastPersistedProgressSig.set(hash, currentSig);
    }
    get().setConfig(bookKey, { updatedAt: now, progressUpdatedAt: nextProgressUpdatedAt });
    const configToSave = { ...config, updatedAt: now, progressUpdatedAt: nextProgressUpdatedAt };
    await appService.saveBookConfig(updatedBook, configToSave, settings);
    scheduleLibrarySave(appService);
  },
  updateBooknotes: (key: string, booknotes: BookNote[]) => {
    let updatedConfig: BookConfig | undefined;
    set((state) => {
      const id = key.split('-')[0]!;
      const book = state.booksData[id];
      if (!book) return state;
      const dedupedBooknotes = Array.from(
        new Map(booknotes.map((item) => [`${item.id}-${item.type}-${item.cfi}`, item])).values(),
      );
      updatedConfig = {
        ...book.config,
        updatedAt: Date.now(),
        booknotes: dedupedBooknotes,
      };
      return {
        booksData: {
          ...state.booksData,
          [id]: {
            ...book,
            config: {
              ...book.config,
              updatedAt: Date.now(),
              booknotes: dedupedBooknotes,
            },
          },
        },
      };
    });
    return updatedConfig;
  },
}));
