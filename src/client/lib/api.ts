'use client';

import {useMutation, useQuery, useQueryClient} from '@tanstack/react-query';
import type {GroupDetail, QueueResponse, StatusResponse, SyncJob, SyncStatusResponse} from '@/shared/types';

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
