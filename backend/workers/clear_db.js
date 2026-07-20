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
    const baseUrl = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents`;

    const collectionsToClear = [
      'customers',
      'installations',
      'subscriptions',
      'device_transfers',
      'hardware_trials',
      'audit_logs',
      'payments',
      'idempotency_keys'
    ];

    for (const collection of collectionsToClear) {
      console.log(`Clearing collection: ${collection}...`);
      
      // 1. List documents
      const queryPayload = {
        structuredQuery: {
          from: [{ collectionId: collection }],
          select: { fields: [{ fieldPath: '__name__' }] }
        }
      };

      const res = await fetch(`${baseUrl}:runQuery`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token.token}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(queryPayload)
      });

      const data = await res.json();
      
      if (!Array.isArray(data) || data.length === 0 || !data[0].document) {
        console.log(`  -> No documents found in ${collection}`);
        continue;
      }

      console.log(`  -> Found ${data.length} documents. Deleting...`);

      for (const item of data) {
        if (item.document && item.document.name) {
          const docName = item.document.name;
          const deleteRes = await fetch(`https://firestore.googleapis.com/v1/${docName}`, {
            method: 'DELETE',
            headers: {
              'Authorization': `Bearer ${token.token}`
            }
          });
          if (deleteRes.ok) {
            console.log(`    - Deleted ${docName}`);
          } else {
            console.error(`    - Failed to delete ${docName}:`, await deleteRes.text());
          }
        }
      }
    }
    
    console.log('Database cleared successfully (except plans and system_configs).');
  } catch (err) {
    console.error('Error:', err);
  }
}

main();
