const { GoogleAuth } = require('google-auth-library');

async function main() {
  try {
    const auth = new GoogleAuth({
      keyFile: 'D:\\VendorSoft_Secrets\\Firebase\\vendorpro-491c4-firebase-adminsdk-fbsvc-85a5e340f5.json',
      scopes: ['https://www.googleapis.com/auth/datastore']
    });

    const client = await auth.getClient();
    const token = await client.getAccessToken();
    console.log('Successfully got token:', token.token.substring(0, 15) + '...');

    const projectId = 'vendorpro-491c4';
    const url = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents:runQuery`;
    
    const queryPayload = {
      structuredQuery: {
        from: [{ collectionId: 'customers' }]
      }
    };

    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${token.token}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(queryPayload)
    });

    const data = await res.json();
    console.log('Firestore Response Status:', res.status);
    console.log('Firestore Response Body:', JSON.stringify(data, null, 2));

  } catch (err) {
    console.error('Error:', err);
  }
}

main();
