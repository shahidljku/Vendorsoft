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
    const baseUrl = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents`;
    const collection = 'device_transfers';
    
    let res = await fetch(`${baseUrl}:runQuery`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${token.token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ structuredQuery: { from: [{ collectionId: collection }], select: { fields: [{ fieldPath: '__name__' }] } } })
    });
    let data = await res.json();
    if (!Array.isArray(data) || data.length === 0 || !data[0].document) {
      console.log(`No documents found in ${collection}`);
      return;
    }
    for (const item of data) {
      if (item.document && item.document.name) {
        const docName = item.document.name;
        await fetch(`https://firestore.googleapis.com/v1/${docName}`, {
          method: 'DELETE', headers: { 'Authorization': `Bearer ${token.token}` }
        });
        console.log(`Deleted ${docName}`);
      }
    }
  } catch(e) { console.error(e); }
}
main();
