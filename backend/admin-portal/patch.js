const fs = require('fs');

const path = 'e:/image_sender/backend/admin-portal/app.js';
let content = fs.readFileSync(path, 'utf8');

// 1. Replace the top initialization block
const topPattern = /\/\*\*[\s\S]*?loadPlans\(\);\r?\n\}\);/m;
const topReplacement = `/**
 * VendSoft Control Plane — Admin Portal Client Logic (app.js)
 * Secured with Firebase Authentication.
 */

const apiBaseUrl = 'https://vendsoft-api-worker.vendorproapk.workers.dev/api/v1';

const firebaseConfig = {
  apiKey: 'AIzaSyBIdrUq8UoLidU4xBSLxaj_rN24lqTtKxg',
  authDomain: 'vendorpro-491c4.firebaseapp.com',
  projectId: 'vendorpro-491c4',
  appId: '1:690486665138:web:0ccae1e54fedb8bac48eab'
};

firebase.initializeApp(firebaseConfig);
const auth = firebase.auth();

async function getAuthHeaders() {
  const user = auth.currentUser;
  if (!user) throw new Error('Not authenticated');
  const token = await user.getIdToken();
  return {
    'Authorization': \`Bearer \${token}\`,
    'Content-Type': 'application/json'
  };
}

document.addEventListener('DOMContentLoaded', () => {
  setupNavigation();
  setupEventListeners();
  
  // Login / Auth Flow
  const btnGoogleSignIn = document.getElementById('btnGoogleSignIn');
  const btnLogout = document.getElementById('btnLogout');
  const loginScreen = document.getElementById('loginScreen');
  const mainDashboard = document.getElementById('mainDashboard');
  const authPill = document.getElementById('authPill');
  const adminStatusText = document.getElementById('adminStatusText');
  const loginError = document.getElementById('loginError');

  btnGoogleSignIn.addEventListener('click', async () => {
    try {
      const provider = new firebase.auth.GoogleAuthProvider();
      await auth.signInWithPopup(provider);
    } catch (err) {
      loginError.textContent = err.message;
      loginError.style.display = 'block';
    }
  });

  btnLogout.addEventListener('click', async () => {
    await auth.signOut();
  });

  auth.onAuthStateChanged((user) => {
    if (user) {
      loginScreen.classList.remove('active');
      mainDashboard.style.display = 'flex';
      authPill.style.display = 'flex';
      adminStatusText.textContent = user.email;
      
      // Load initial data
      loadCustomers();
      loadPendingTransfers();
      loadSystemConfigs();
      loadAuditLogs();
      loadPlans();
    } else {
      loginScreen.classList.add('active');
      mainDashboard.style.display = 'none';
      authPill.style.display = 'none';
    }
  });
});`;

content = content.replace(topPattern, topReplacement);

// 2. Patch the setupNavigation event listener for API URL that we removed
const navPattern = /const apiSelect = document\.getElementById\('apiBaseUrl'\);[\s\S]*?\}\);/m;
content = content.replace(navPattern, '');

// 3. Patch authHeaders in fetch calls
content = content.replace(/headers:\s*authHeaders/g, 'headers: await getAuthHeaders()');

// 4. Patch upload-apk-chunk fetch which explicitly uses x-admin-secret
const uploadFetchPattern = /headers:\s*\{\s*'x-admin-secret':\s*authHeaders\['x-admin-secret'\]\s*\}/g;
content = content.replace(uploadFetchPattern, 'headers: await getAuthHeaders()');

// 5. Remove any leftover console.log or sessionStorage references (security)
content = content.replace(/console\.log\(.*?\);/g, '');
content = content.replace(/sessionStorage\.getItem\(.*?\);/g, '');
content = content.replace(/sessionStorage\.setItem\(.*?\);/g, '');

// Fix public endpoint /config/system which didn't use authHeaders, we can leave it as is or await getAuthHeaders() for admin endpoint
// Wait, the public config fetch is: fetch(\`\${apiBaseUrl}/config/system\`, { method: 'GET' }); - that's fine.
// The admin config fetch is: fetch(\`\${apiBaseUrl}/admin/config/system\`, { method: 'PUT', headers: authHeaders, body: ... });

fs.writeFileSync(path, content, 'utf8');
console.log('Successfully patched app.js');
