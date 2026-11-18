import type {
  ApiErrorResponse,
  ErrorsRequest,
  ErrorsResponse,
  StatusResponse,
  StressMemoryRequest,
  StressMemoryResponse,
} from './types'

async function request<TResponse>(
  path: string,
  init?: RequestInit
): Promise<TResponse> {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...init,
  })
  const data = (await res.json()) as TResponse | ApiErrorResponse
  if (!res.ok) {
    const message =
      (data as ApiErrorResponse).error ?? `Request failed with status ${res.status}`
    throw new Error(message)
  }
  return data as TResponse
}

export function postErrors(body: ErrorsRequest): Promise<ErrorsResponse> {
  return request<ErrorsResponse>('/api/errors', {
    method: 'POST',
    body: JSON.stringify(body),
  })
}

export function postStressMemory(
  body: StressMemoryRequest
): Promise<StressMemoryResponse> {
  return request<StressMemoryResponse>('/api/stress/memory', {
    method: 'POST',
    body: JSON.stringify(body),
  })
}

export function getStatus(): Promise<StatusResponse> {
  return request<StatusResponse>('/api/status', { method: 'GET' })
}
