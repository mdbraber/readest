'use client';

import clsx from 'clsx';
import React, { useEffect, useMemo, useState } from 'react';
import { MdCheckCircle, MdRefresh, MdSave, MdSettingsEthernet } from 'react-icons/md';
import { useTranslation } from '@/hooks/useTranslation';
import {
  clearCustomServerConfig,
  CustomServerConfigError,
  loadCustomServerConfig,
  normalizeServerBaseUrl,
  resolveCustomServerConfig,
  saveCustomServerConfig,
} from '@/services/customServerConfig';
import type { CustomServerConfig } from '@/services/customServerConfig';
import { isTauriAppPlatform } from '@/services/environment';
import { BoxedList, SettingsRow } from './primitives';

type TestState =
  | { status: 'idle'; message?: string }
  | { status: 'success'; message: string; config: CustomServerConfig }
  | { status: 'error'; message: string };

interface ServerSettingsPanelProps {
  compact?: boolean;
}

const maskAnonKey = (key: string | undefined, translate: (key: string) => string) => {
  if (!key) return translate('Not provided');
  if (key.length <= 10) return translate('Hidden');
  return `${key.slice(0, 4)}...${key.slice(-4)}`;
};

const getHost = (url: string | undefined, translate: (key: string) => string) => {
  if (!url) return translate('Not provided');
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
};

const getErrorMessage = (error: unknown, translate: (key: string) => string) => {
  if (error instanceof CustomServerConfigError) {
    switch (error.code) {
      case 'server-not-reachable':
        return translate('Server not reachable');
      case 'invalid-config':
        return translate('Invalid config');
      case 'missing-supabase-config':
        return translate('Missing Supabase config');
      case 'insecure-http':
        return translate('Insecure http not allowed');
      case 'dangerous-secret':
        return translate('Dangerous secret exposed by server config');
      case 'invalid-url':
      default:
        return translate('Invalid server URL');
    }
  }
  return translate('Server not reachable');
};

const ServerSettingsPanel: React.FC<ServerSettingsPanelProps> = ({ compact = false }) => {
  const _ = useTranslation();
  const [serverUrl, setServerUrl] = useState('');
  const [savedConfig, setSavedConfig] = useState<CustomServerConfig | null>(null);
  const [testState, setTestState] = useState<TestState>({ status: 'idle' });
  const [isTesting, setIsTesting] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [isResetting, setIsResetting] = useState(false);

  useEffect(() => {
    const config = loadCustomServerConfig();
    setSavedConfig(config);
    setServerUrl(config?.serverBaseUrl ?? '');
  }, []);

  const effectiveConfig = useMemo(() => {
    if (testState.status === 'success') return testState.config;
    return savedConfig;
  }, [savedConfig, testState]);

  const allowInsecureHttp = process.env.NODE_ENV === 'development';

  const handleTestConnection = async () => {
    setIsTesting(true);
    try {
      const config = await resolveCustomServerConfig(serverUrl, { allowInsecureHttp });
      setTestState({
        status: 'success',
        message: _('Connection successful'),
        config,
      });
    } catch (error) {
      setTestState({ status: 'error', message: getErrorMessage(error, _) });
    } finally {
      setIsTesting(false);
    }
  };

  const handleSave = async () => {
    setIsSaving(true);
    try {
      const normalizedInput = normalizeServerBaseUrl(serverUrl, { allowInsecureHttp });
      const config =
        testState.status === 'success' && testState.config.serverBaseUrl === normalizedInput
          ? testState.config
          : await resolveCustomServerConfig(serverUrl, { allowInsecureHttp });
      await saveCustomServerConfig(config, { resetSession: true });
      setSavedConfig(config);
      setTestState({
        status: 'success',
        message: _('Server saved. Please sign in again.'),
        config,
      });
    } catch (error) {
      setTestState({ status: 'error', message: getErrorMessage(error, _) });
    } finally {
      setIsSaving(false);
    }
  };

  const handleReset = async () => {
    setIsResetting(true);
    try {
      await clearCustomServerConfig({ resetSession: true });
      setSavedConfig(null);
      setServerUrl('');
      setTestState({ status: 'idle', message: _('Server settings reset. Please sign in again.') });
    } finally {
      setIsResetting(false);
    }
  };

  const statusText =
    testState.message ?? (savedConfig ? _('Custom server enabled') : _('Default server'));

  return (
    <div className={clsx(compact ? 'w-full' : 'my-4 w-full space-y-6')}>
      <BoxedList
        title={_('Server Settings')}
        description={
          isTauriAppPlatform()
            ? _('Changing servers signs you out so sessions cannot cross servers.')
            : _('Custom servers are available in the desktop and mobile app.')
        }
        data-setting-id='settings.server'
      >
        <SettingsRow
          label={_('Server URL')}
          description={statusText}
          align='start'
          data-setting-id='settings.server.url'
        >
          <div className='flex w-full max-w-full flex-col items-end gap-2 sm:max-w-[60%]'>
            <input
              className='input settings-content input-bordered h-9 w-full rounded-md text-end'
              value={serverUrl}
              placeholder='https://readest.example.com'
              onChange={(event) => {
                setServerUrl(event.target.value);
                setTestState({ status: 'idle' });
              }}
            />
            {testState.status === 'error' && (
              <span className='text-error text-end text-xs'>{testState.message}</span>
            )}
            {testState.status === 'success' && (
              <span className='text-success flex items-center gap-1 text-end text-xs'>
                <MdCheckCircle />
                {testState.message}
              </span>
            )}
          </div>
        </SettingsRow>
        <SettingsRow label={_('API host')} description={getHost(effectiveConfig?.apiBaseUrl, _)} />
        <SettingsRow
          label={_('Supabase host')}
          description={getHost(effectiveConfig?.supabaseUrl, _)}
        />
        <SettingsRow
          label={_('Supabase anon key')}
          description={maskAnonKey(effectiveConfig?.supabaseAnonKey, _)}
        />
        <SettingsRow label={_('Actions')} align='start'>
          <div className='flex flex-wrap justify-end gap-2'>
            <button
              type='button'
              className='btn btn-sm'
              disabled={!serverUrl.trim() || isTesting}
              onClick={handleTestConnection}
            >
              <MdSettingsEthernet />
              {_('Test connection')}
            </button>
            <button
              type='button'
              className='btn btn-primary btn-sm'
              disabled={!serverUrl.trim() || isSaving}
              onClick={handleSave}
            >
              <MdSave />
              {_('Save')}
            </button>
            <button
              type='button'
              className='btn btn-ghost btn-sm'
              disabled={isResetting || (!savedConfig && !serverUrl)}
              onClick={handleReset}
            >
              <MdRefresh />
              {_('Reset to default')}
            </button>
          </div>
        </SettingsRow>
      </BoxedList>
    </div>
  );
};

export default ServerSettingsPanel;
