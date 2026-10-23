'use client';

import {useMutation, useQuery, useQueryClient} from '@tanstack/react-query';
import type {GroupDetail, PackageProfilesResponse, QueueResponse, StatusResponse, SyncJob, SyncStatusResponse} from '@/shared/types';
import type {ActionInput, ActionKey} from '@/shared/actions';

export class ApiError extends Error {
  constructor(message: string, public status: number) {
    super(message);
  }
}

async function getJson<T>(url: string): Promise<T> {
  let res: Response;
  try {
    res = await fetch(url, {cache: 'no-store'});
  } catch {
    throw new ApiError('The local server is not reachable', 0);
  }
  const body = await res.json().catch(() => null);
  if (!res.ok) throw new ApiError(body?.error ?? `Request failed (${res.status})`, res.status);
  return body as T;
}

// Live data only. On failure the last successful data stays on screen (marked stale); no preview
// or synthetic data is ever substituted.
export function useQueue() {
  return useQuery({queryKey: ['queue'], queryFn: () => getJson<QueueResponse>('/api/queue'), refetchInterval: 60_000});
}

export function useGroupDetail(id: number | null) {
  return useQuery({
    queryKey: ['group', id],
    queryFn: () => getJson<GroupDetail>(`/api/groups/${id}`),
    enabled: id != null,
  });
}

export function useStatus() {
  return useQuery({queryKey: ['status'], queryFn: () => getJson<StatusResponse>('/api/status'), refetchInterval: 120_000});
}

export function useSyncStatus() {
  return useQuery({
    queryKey: ['sync'],
    queryFn: () => getJson<SyncStatusResponse>('/api/sync'),
    // Poll quickly only while a sync is actually running.
    refetchInterval: q => (q.state.data?.job?.state === 'running' ? 1000 : 30_000),
  });
}

export function useStartSync() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (): Promise<SyncJob> => {
      const res = await fetch('/api/sync', {method: 'POST'}).catch(() => {
        throw new ApiError('The local server is not reachable', 0);
      });
      const body = await res.json().catch(() => null);
      if (!res.ok) throw new ApiError(body?.error ?? `Sync could not start (${res.status})`, res.status);
      return body.job as SyncJob;
    },
    onSettled: () => qc.invalidateQueries({queryKey: ['sync']}),
  });
}

export function usePackageProfiles() {
  return useQuery({queryKey: ['package-profiles'], queryFn: () => getJson<PackageProfilesResponse>('/api/package-profiles')});
}

// One staff action (POST /api/actions/<key>). Afterwards every view that could show the change is
// refreshed from the database; nothing is updated optimistically.
export function useAction<K extends ActionKey>(key: K) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (input: ActionInput<K>): Promise<Record<string, unknown>> => {
      const res = await fetch(`/api/actions/${key}`, {
        method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(input),
      }).catch(() => {
        throw new ApiError('The local server is not reachable', 0);
      });
      const body = await res.json().catch(() => null);
      if (!res.ok) throw new ApiError(body?.error ?? `The action failed (${res.status})`, res.status);
      return body.result;
    },
    onSettled: () => Promise.all([
      qc.invalidateQueries({queryKey: ['group']}),
      qc.invalidateQueries({queryKey: ['queue']}),
      qc.invalidateQueries({queryKey: ['package-profiles']}),
    ]),
  });
}
