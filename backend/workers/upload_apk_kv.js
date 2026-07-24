const fs = require('fs');
const { execSync } = require('child_process');
const path = require('path');

const APK_PATH = 'e:\\image_sender\\build\\app\\outputs\\flutter-apk\\app-release.apk';
const VERSION = '1.0.0'; 
const CHUNK_SIZE = 20 * 1024 * 1024; // 20MB

if (!fs.existsSync(APK_PATH)) {
    console.error('APK not found at', APK_PATH);
    process.exit(1);
}

const fileBuffer = fs.readFileSync(APK_PATH);
const totalSize = fileBuffer.length;
const totalChunks = Math.ceil(totalSize / CHUNK_SIZE);

console.log(`Uploading ${VERSION} APK (${totalSize} bytes) in ${totalChunks} chunks...`);

for (let i = 0; i < totalChunks; i++) {
    const start = i * CHUNK_SIZE;
    const end = Math.min(start + CHUNK_SIZE, totalSize);
    const chunk = fileBuffer.slice(start, end);
    
    const chunkPath = path.join(__dirname, `chunk_${i}.tmp`);
    fs.writeFileSync(chunkPath, chunk);
    
    const chunkKey = `apk-${VERSION}-chunk-${i}`;
    console.log(`Uploading ${chunkKey}...`);
    
    execSync(`npx wrangler kv:key put --binding=APK_STORE "${chunkKey}" --path="${chunkPath}"`, { stdio: 'inherit' });
    
    fs.unlinkSync(chunkPath);
}

const metaKey = `apk-${VERSION}-meta`;
const metadata = {
    version: VERSION,
    totalChunks,
    totalSize,
    fileName: `vendorsoft-v${VERSION}.apk`,
    contentType: 'application/vnd.android.package-archive',
    uploadedAt: Date.now()
};

const metaPath = path.join(__dirname, 'meta.tmp');
fs.writeFileSync(metaPath, JSON.stringify(metadata));
console.log(`Uploading ${metaKey}...`);
execSync(`npx wrangler kv:key put --binding=APK_STORE "${metaKey}" --path="${metaPath}"`, { stdio: 'inherit' });
fs.unlinkSync(metaPath);

console.log('Upload complete!');
