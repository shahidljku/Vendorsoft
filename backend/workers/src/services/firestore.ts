import { Env } from '../types';

/**
 * Service Account JSON format expected in Env.FIRESTORE_SA_KEY
 */
interface ServiceAccount {
  type: string;
  project_id: string;
  private_key_id: string;
  private_key: string;
  client_email: string;
  client_id: string;
  auth_uri: string;
  token_uri: string;
}

/**
 * Cached OAuth2 token for Firestore REST API
 */
let cachedToken: { accessToken: string; expiresAt: number } | null = null;

/**
 * Retrieves a valid OAuth2 Access Token for Google Cloud Firestore via Service Account Web Crypto RSA signing.
 */
export async function getFirestoreAccessToken(env: Env): Promise<string> {
  // Return cached token if valid for at least 60 more seconds
  if (cachedToken && cachedToken.expiresAt > Date.now() + 60000) {
    return cachedToken.accessToken;
  }

  if (!env.FIRESTORE_SA_KEY) {
    throw new Error('Missing FIRESTORE_SA_KEY in environment secrets.');
  }

  let sa: ServiceAccount;
  try {
    sa = JSON.parse(env.FIRESTORE_SA_KEY);
  } catch (err) {
    throw new Error('FIRESTORE_SA_KEY secret is not valid JSON.');
  }

  const iat = Math.floor(Date.now() / 1000);
  const exp = iat + 3600; // 1 hour expiration

  const header = {
    alg: 'RS256',
    typ: 'JWT'
  };

  const payload = {
    iss: sa.client_email,
    sub: sa.client_email,
    aud: 'https://oauth2.googleapis.com/token',
    iat,
    exp,
    scope: 'https://www.googleapis.com/auth/datastore'
  };

  const base64Header = base64UrlEncode(JSON.stringify(header));
  const base64Payload = base64UrlEncode(JSON.stringify(payload));
  const unsignedToken = `${base64Header}.${base64Payload}`;

  // Import Service Account private key using Web Crypto API
  const pemHeader = '-----BEGIN PRIVATE KEY-----';
  const pemFooter = '-----END PRIVATE KEY-----';
  const pemContents = sa.private_key
    .replace(pemHeader, '')
    .replace(pemFooter, '')
    .replace(/\s+/g, '');

  const binaryDer = str2ab(atob(pemContents));
  const privateKey = await crypto.subtle.importKey(
    'pkcs8',
    binaryDer,
    {
      name: 'RSASSA-PKCS1-v1_5',
      hash: { name: 'SHA-256' }
    },
    false,
    ['sign']
  );

  const signatureBuffer = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    privateKey,
    new TextEncoder().encode(unsignedToken)
  );

  const signature = base64UrlEncodeBuffer(signatureBuffer);
  const jwtAssertion = `${unsignedToken}.${signature}`;

  // Exchange JWT assertion for OAuth2 access token
  const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwtAssertion}`
  });

  if (!tokenResponse.ok) {
    const errorText = await tokenResponse.text();
    throw new Error(`Failed to exchange Service Account JWT for token: ${errorText}`);
  }

  const tokenData = (await tokenResponse.json()) as { access_token: string; expires_in: number };
  cachedToken = {
    accessToken: tokenData.access_token,
    expiresAt: Date.now() + (tokenData.expires_in * 1000)
  };

  return cachedToken.accessToken;
}

/**
 * In-memory fallback database for local execution (`wrangler dev`) when FIRESTORE_SA_KEY is not injected.
 * Exactly simulates atomic transactions and precondition enforcement (`requireDoesNotExist`).
 */
export const localStore = new Map<string, Record<string, any>>();

/**
 * Reads a single document from Google Cloud Firestore via REST API (or localStore during local dev).
 */
export async function getDocument(env: Env, collectionPath: string, documentId: string): Promise<any | null> {
  if (!env.FIRESTORE_SA_KEY) {
    return localStore.get(`${collectionPath}/${documentId}`) || null;
  }

  const projectId = env.GCP_PROJECT_ID || 'vendsoft-prod';
  const url = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents/${collectionPath}/${documentId}`;

  // If we don't have Service Account keys configured locally yet (e.g., local dev before secrets injected),
  // attempt public/unauthenticated read first or return fallback mock if safe
  let headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (env.FIRESTORE_SA_KEY) {
    try {
      const token = await getFirestoreAccessToken(env);
      headers['Authorization'] = `Bearer ${token}`;
    } catch (err) {
      console.error('Error getting Service Account token for Firestore read:', err);
    }
  }

  const response = await fetch(url, { method: 'GET', headers });

  if (response.status === 404) {
    return null;
  }

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`Firestore getDocument error (${response.status}): ${errText}`);
  }

  const data = await response.json();
  return parseFirestoreDocument(data);
}

/**
 * Queries documents in a collection matching specified filters via Firestore REST `:runQuery` (or localStore during local dev).
 */
export async function queryCollection(
  env: Env,
  collectionPath: string,
  filters: Array<{ field: string; op: 'EQUAL' | 'GREATER_THAN' | 'LESS_THAN'; value: any }>
): Promise<any[]> {
  if (!env.FIRESTORE_SA_KEY) {
    const results: any[] = [];
    for (const [key, doc] of localStore.entries()) {
      if (!key.startsWith(`${collectionPath}/`)) continue;
      let matches = true;
      for (const filter of filters) {
        const docVal = doc[filter.field];
        if (filter.op === 'EQUAL' && docVal !== filter.value) matches = false;
        else if (filter.op === 'GREATER_THAN' && !(docVal > filter.value)) matches = false;
        else if (filter.op === 'LESS_THAN' && !(docVal < filter.value)) matches = false;
      }
      if (matches) results.push(doc);
    }
    return results;
  }

  const projectId = env.GCP_PROJECT_ID || 'vendsoft-prod';
  const url = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents:runQuery`;

  let headers: Record<string, string> = { 'Content-Type': 'application/json' };
  try {
    const token = await getFirestoreAccessToken(env);
    headers['Authorization'] = `Bearer ${token}`;
  } catch (err) {
    console.error('Error getting Service Account token for Firestore query:', err);
  }

  const filterExpressions = filters.map((f) => {
    let valObj: any = { stringValue: String(f.value) };
    if (typeof f.value === 'boolean') valObj = { booleanValue: f.value };
    else if (typeof f.value === 'number') valObj = Number.isInteger(f.value) ? { integerValue: f.value.toString() } : { doubleValue: f.value };
    return {
      fieldFilter: {
        field: { fieldPath: f.field },
        op: f.op,
        value: valObj
      }
    };
  });

  let whereClause: any = undefined;
  if (filterExpressions.length === 1) {
    whereClause = filterExpressions[0];
  } else if (filterExpressions.length > 1) {
    whereClause = {
      compositeFilter: {
        op: 'AND',
        filters: filterExpressions
      }
    };
  }

  const queryPayload = {
    structuredQuery: {
      from: [{ collectionId: collectionPath }],
      where: whereClause
    }
  };

  const response = await fetch(url, { method: 'POST', headers, body: JSON.stringify(queryPayload) });
  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`Firestore queryCollection error (${response.status}): ${errText}`);
  }

  const rawResults = await response.json();
  if (!Array.isArray(rawResults)) return [];

  const parsedList: any[] = [];
  for (const item of rawResults) {
    if (item && item.document && item.document.fields) {
      parsedList.push(parseFields(item.document.fields));
    }
  }
  return parsedList;
}

/**
 * Converts a Firestore REST API typed document (`{ fields: { key: { stringValue: 'val' } } }`) to plain JS object.
 */
export function parseFirestoreDocument(doc: any): any {
  if (!doc || !doc.fields) return null;
  return parseFields(doc.fields);
}

function parseFields(fields: Record<string, any>): Record<string, any> {
  const result: Record<string, any> = {};
  for (const key of Object.keys(fields)) {
    const valueObj = fields[key];
    if ('stringValue' in valueObj) result[key] = valueObj.stringValue;
    else if ('booleanValue' in valueObj) result[key] = valueObj.booleanValue;
    else if ('integerValue' in valueObj) result[key] = parseInt(valueObj.integerValue, 10);
    else if ('doubleValue' in valueObj) result[key] = parseFloat(valueObj.doubleValue);
    else if ('timestampValue' in valueObj) result[key] = valueObj.timestampValue;
    else if ('nullValue' in valueObj) result[key] = null;
    else if ('mapValue' in valueObj) result[key] = parseFields(valueObj.mapValue.fields || {});
    else if ('arrayValue' in valueObj) {
      result[key] = (valueObj.arrayValue.values || []).map((v: any) => {
        if ('stringValue' in v) return v.stringValue;
        if ('mapValue' in v) return parseFields(v.mapValue.fields || {});
        return v;
      });
    }
  }
  return result;
}

// Helpers for writing documents to Firestore REST API
export function formatFirestoreDocument(obj: Record<string, any>): { fields: Record<string, any> } {
  const fields: Record<string, any> = {};
  for (const key of Object.keys(obj)) {
    const val = obj[key];
    if (val === null || val === undefined) {
      fields[key] = { nullValue: null };
    } else if (typeof val === 'string') {
      fields[key] = { stringValue: val };
    } else if (typeof val === 'boolean') {
      fields[key] = { booleanValue: val };
    } else if (typeof val === 'number') {
      if (Number.isInteger(val)) {
        fields[key] = { integerValue: val.toString() };
      } else {
        fields[key] = { doubleValue: val };
      }
    } else if (typeof val === 'object' && !Array.isArray(val)) {
      fields[key] = { mapValue: formatFirestoreDocument(val) };
    } else if (Array.isArray(val)) {
      fields[key] = {
        arrayValue: {
          values: val.map((v) => {
            if (typeof v === 'string') return { stringValue: v };
            if (typeof v === 'boolean') return { booleanValue: v };
            if (typeof v === 'number') return Number.isInteger(v) ? { integerValue: v.toString() } : { doubleValue: v };
            return { stringValue: JSON.stringify(v) };
          })
        }
      };
    }
  }
  return { fields };
}

export async function setDocument(env: Env, collectionPath: string, documentId: string, data: Record<string, any>): Promise<void> {
  if (!env.FIRESTORE_SA_KEY) {
    localStore.set(`${collectionPath}/${documentId}`, data);
    return;
  }

  const projectId = env.GCP_PROJECT_ID || 'vendsoft-prod';
  const url = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents/${collectionPath}/${documentId}`;

  let headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (env.FIRESTORE_SA_KEY) {
    try {
      const token = await getFirestoreAccessToken(env);
      headers['Authorization'] = `Bearer ${token}`;
    } catch (err) {
      console.error('Error getting Service Account token for Firestore write:', err);
    }
  }

  const payload = formatFirestoreDocument(data);
  const response = await fetch(url, {
    method: 'PATCH',
    headers,
    body: JSON.stringify(payload)
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`Firestore setDocument error (${response.status}): ${errText}`);
  }
}

/**
 * Commits multiple document writes atomically using Firestore REST API (`:commit`).
 * If any write fails preconditions (e.g. requireDoesNotExist for idempotency locks),
 * the entire batch of writes is aborted with zero changes applied to the database.
 */
export async function commitAtomicWrites(
  env: Env,
  writes: Array<{
    collectionPath: string;
    documentId: string;
    data: Record<string, any>;
    requireDoesNotExist?: boolean;
  }>
): Promise<void> {
  if (!env.FIRESTORE_SA_KEY) {
    // Check preconditions atomically before applying any write (`All or Nothing`)
    for (const w of writes) {
      const key = `${w.collectionPath}/${w.documentId}`;
      if (w.requireDoesNotExist === true && localStore.has(key)) {
        const raceErr = new Error(`IDEMPOTENCY_CONCURRENCY_ABORT: Document ${key} already exists.`);
        (raceErr as any).code = 'ALREADY_EXISTS';
        throw raceErr;
      }
    }
    // Apply all writes atomically inside local store
    for (const w of writes) {
      localStore.set(`${w.collectionPath}/${w.documentId}`, w.data);
    }
    return;
  }

  const projectId = env.GCP_PROJECT_ID || 'vendsoft-prod';
  const url = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents:commit`;

  let headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (env.FIRESTORE_SA_KEY) {
    try {
      const token = await getFirestoreAccessToken(env);
      headers['Authorization'] = `Bearer ${token}`;
    } catch (err) {
      console.error('Error getting Service Account token for Firestore commit:', err);
    }
  }

  const payloadWrites = writes.map((w) => {
    const docPath = `projects/${projectId}/databases/(default)/documents/${w.collectionPath}/${w.documentId}`;
    const formatted = formatFirestoreDocument(w.data);
    const writeOp: any = {
      update: {
        name: docPath,
        fields: formatted.fields
      }
    };
    if (w.requireDoesNotExist === true) {
      writeOp.currentDocument = { exists: false };
    }
    return writeOp;
  });

  const response = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify({ writes: payloadWrites })
  });

  if (!response.ok) {
    const errText = await response.text();
    const status = response.status;
    if (status === 400 || status === 409 || errText.includes('ALREADY_EXISTS') || errText.includes('FAILED_PRECONDITION') || errText.includes('already exists')) {
      const raceErr = new Error(`IDEMPOTENCY_CONCURRENCY_ABORT: ${errText}`);
      (raceErr as any).code = 'ALREADY_EXISTS';
      throw raceErr;
    }
    throw new Error(`Firestore commitAtomicWrites error (${status}): ${errText}`);
  }
}

// Helpers for base64url encoding in Web Crypto
function base64UrlEncode(str: string): string {
  return btoa(str).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64UrlEncodeBuffer(buffer: ArrayBuffer): string {
  let binary = '';
  const bytes = new Uint8Array(buffer);
  const len = bytes.byteLength;
  for (let i = 0; i < len; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function str2ab(str: string): ArrayBuffer {
  const buf = new ArrayBuffer(str.length);
  const bufView = new Uint8Array(buf);
  for (let i = 0, strLen = str.length; i < strLen; i++) {
    bufView[i] = str.charCodeAt(i);
  }
  return buf;
}

/**
 * Standardized system audit log writer (`Phase 4 - Audit Logs & Admin Portal`).
 */
export async function logAuditEvent(env: Env, severityOrAction: string, metadata: Record<string, any>): Promise<void> {
  try {
    const logId = `log_${Math.random().toString(36).substring(2, 10).toUpperCase()}`;
    await setDocument(env, 'audit_logs', logId, {
      logId,
      action: severityOrAction,
      severity: 'INFO',
      metadata,
      createdAtEpochMs: Date.now()
    });
  } catch (err) {
    console.error('Failed to write audit log:', err);
  }
}
