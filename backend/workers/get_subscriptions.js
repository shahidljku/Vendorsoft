const { GoogleAuth } = require('google-auth-library');
async function main() {
  try {
    const auth = new GoogleAuth({
      keyFile: 'D:\\VendorSoft_Secrets\\Firebase\\vendorpro-491c4-firebase-adminsdk-fbsvc-85a5e340f5.json',
      scopes: ['https://www.googleapis.com/auth/datastore']
    });
    const client = await auth.getClient();
    const token = await client.getAccessToken();
    const projectId = 'vendorpro-491c4';
    
    let res = await fetch(`https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents:runQuery`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${token.token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ structuredQuery: { from: [{ collectionId: 'subscriptions' }] } })
    });
    console.log("Subscriptions:");
    let data = await res.json();
    for (const item of data) {
      if (item.document) console.log(JSON.stringify(item.document.fields));
    }
  } catch(e) {
    console.error(e);
  }
}
main();
