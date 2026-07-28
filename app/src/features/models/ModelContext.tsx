import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import {
  inspectInstalledModel,
  type ModelInstallationStatus,
} from './storage';

type ModelContextValue = {
  status: ModelInstallationStatus;
  refresh: () => Promise<void>;
};

const ModelContext = createContext<ModelContextValue | undefined>(undefined);

export function ModelProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<ModelInstallationStatus>({
    kind: 'checking',
  });
  const refreshToken = useRef(0);
  const pendingRefresh = useRef<Promise<void> | null>(null);

  const refresh = useCallback((): Promise<void> => {
    if (pendingRefresh.current !== null) return pendingRefresh.current;

    const token = refreshToken.current + 1;
    refreshToken.current = token;
    setStatus({ kind: 'checking' });
    const operation = inspectInstalledModel().then((inspected) => {
      if (refreshToken.current === token) setStatus(inspected);
    });
    pendingRefresh.current = operation;
    void operation.then(
      () => {
        if (pendingRefresh.current === operation) pendingRefresh.current = null;
      },
      () => {
        if (pendingRefresh.current === operation) pendingRefresh.current = null;
      },
    );
    return operation;
  }, []);

  useEffect(() => {
    void refresh();
    return () => {
      refreshToken.current += 1;
      pendingRefresh.current = null;
    };
  }, [refresh]);

  return (
    <ModelContext.Provider value={{ status, refresh }}>
      {children}
    </ModelContext.Provider>
  );
}

export function useInstalledModel(): ModelContextValue {
  const value = useContext(ModelContext);
  if (value === undefined) {
    throw new Error('useInstalledModel must be used within ModelProvider.');
  }
  return value;
}
