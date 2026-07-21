import { Env } from '../types';

/**
 * Handles GET /v1/public/apks/:version.apk
 * Streams a chunked APK file out of Cloudflare KV back to the client.
 */
export async function handlePublicDownloadApk(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const pathParts = url.pathname.split('/');
  const filename = pathParts[pathParts.length - 1]; // e.g., "1.0.0+1.apk"
  
  if (!filename.endsWith('.apk')) {
    return new Response('Invalid file type', { status: 400 });
  }

  const version = filename.replace('.apk', '');
  const metaKey = `apk-${version}-meta`;
  
  const metaStr = await env.APK_STORE.get(metaKey);
  if (!metaStr) {
    return new Response('APK version not found', { status: 404 });
  }

  const meta = JSON.parse(metaStr);
  const totalChunks = meta.totalChunks;

  // Cloudflare Workers omit Content-Length if we return a ReadableStream, which breaks
  // the download progress bar in the mobile app. We assemble the file in memory instead.
  // The max APK size is ~64MB which fits safely inside the 128MB worker memory limit.
  const fullBuffer = new Uint8Array(meta.totalSize);
  let offset = 0;
  
  for (let i = 0; i < totalChunks; i++) {
    const chunkKey = `apk-${version}-chunk-${i}`;
    const chunkArrayBuffer = await env.APK_STORE.get(chunkKey, 'arrayBuffer');
    
    if (!chunkArrayBuffer) {
      console.error(`Missing chunk ${i} for APK version ${version}`);
      return new Response('APK file is corrupted or missing chunks', { status: 500 });
    }

    fullBuffer.set(new Uint8Array(chunkArrayBuffer), offset);
    offset += chunkArrayBuffer.byteLength;
  }

  return new Response(fullBuffer, {
    status: 200,
    headers: {
      'Content-Type': meta.contentType || 'application/vnd.android.package-archive',
      'Content-Disposition': `attachment; filename="${meta.fileName}"`,
      'Content-Length': meta.totalSize.toString(),
      'Cache-Control': 'public, max-age=3600',
      'Access-Control-Allow-Origin': '*'
    }
  });
}
