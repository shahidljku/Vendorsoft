const fs = require('fs');
const { execSync } = require('child_process');

const sa = fs.readFileSync('D:\\VendorSoft_Secrets\\Firebase\\vendorpro-491c4-firebase-adminsdk-fbsvc-85a5e340f5.json', 'utf8');

try {
  execSync('npx wrangler secret put FIRESTORE_SA_KEY', {
    input: sa,
    stdio: ['pipe', 'inherit', 'inherit']
  });
  console.log('Successfully uploaded secret via Node!');
} catch (e) {
  console.error('Failed:', e);
}
