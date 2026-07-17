const fs = require('fs');
const crypto = require('crypto');

function base64UrlEncode(str) {
  return Buffer.from(str).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function base64UrlEncodeBuffer(buffer) {
  return buffer.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function main() {
  const saRaw = fs.readFileSync('D:\\VendorSoft_Secrets\\Firebase\\vendorpro-491c4-firebase-adminsdk-fbsvc-85a5e340f5.json', 'utf8');
  const sa = JSON.parse(saRaw);

  const iat = Math.floor(Date.now() / 1000);
  const exp = iat + 3600;

  const header = { alg: 'RS256', typ: 'JWT' };
  const payload = {
    iss: sa.client_email,
    sub: sa.client_email,
    aud: 'https://oauth2.googleapis.com/token',
    iat,
    exp,
    scope: 'https://www.googleapis.com/auth/datastore'
  };

  const unsignedToken = `${base64UrlEncode(JSON.stringify(header))}.${base64UrlEncode(JSON.stringify(payload))}`;
  const sign = crypto.createSign('RSA-SHA256');
  sign.update(unsignedToken);
  const signature = sign.sign(sa.private_key, 'base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  
  const jwtAssertion = `${unsignedToken}.${signature}`;

  const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwtAssertion}`
  });

  const tokenData = await tokenResponse.json();
  console.log('Token Response:', tokenData);

  if (tokenData.access_token) {
    const url = `https://firestore.googleapis.com/v1/projects/vendorpro-491c4/databases/(default)/documents/system_configs/global`;
    const res = await fetch(url, {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${tokenData.access_token}`,
        'Content-Type': 'application/json'
      }
    });
    console.log('Firestore Status:', res.status);
    const body = await res.text();
    console.log('Firestore Body:', body);
  }
}

main();
