/**
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
    'Authorization': `Bearer ${token}`,
    'Content-Type': 'application/json'
  };
}

// Global fetch interceptor to enforce Zero Trust mid-session revocation
const originalFetch = window.fetch;
window.fetch = async function(...args) {
  const response = await originalFetch(...args);
  if (response.status === 401 || response.status === 403) {
    const url = args[0] ? args[0].toString() : '';
    if (url.includes(apiBaseUrl)) {
      console.warn('Zero Trust Enforcement: Unauthorized API request detected. Revoking session.');
      await auth.signOut();
    }
  }
  return response;
};

document.addEventListener('DOMContentLoaded', () => {
  setupNavigation();
  setupEventListeners();
  
  // Login / Auth Flow
  const btnGoogleSignIn = document.getElementById('btnGoogleSignIn');
  const btnLogout = document.getElementById('btnLogout');
  const loginScreen = document.getElementById('loginScreen');
  const initialLoadingScreen = document.getElementById('initialLoadingScreen');
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

  auth.onAuthStateChanged(async (user) => {
    if (user) {
      // Zero Trust: Do NOT render UI yet. Verify with backend first.
      adminStatusText.textContent = 'Verifying security clearance...';
      try {
        const verifyResp = await fetch(`${apiBaseUrl}/admin/auth/verify`, {
          method: 'GET',
          headers: await getAuthHeaders()
        });
        
        if (!verifyResp.ok) {
          throw new Error('Unauthorized by edge backend.');
        }

        initialLoadingScreen.classList.remove('active');
        loginScreen.classList.remove('active');
        mainDashboard.style.display = 'flex';
        authPill.style.display = 'flex';
        adminStatusText.textContent = user.email;
        
        // Load initial data only after confirmation
        loadCustomers();
        loadPendingTransfers();
        loadSystemConfigs();
        loadAuditLogs();
        loadPlans();
      } catch (err) {
        console.error('Zero Trust Verification Failed:', err);
        await auth.signOut();
        initialLoadingScreen.classList.remove('active');
        loginScreen.classList.add('active');
        loginError.textContent = "Access denied. This Google account is not authorized.";
        loginError.style.display = 'block';
      }
    } else {
      initialLoadingScreen.classList.remove('active');
      loginScreen.classList.add('active');
      mainDashboard.style.display = 'none';
      authPill.style.display = 'none';
    }
  });
});

function setupNavigation() {
  const tabButtons = document.querySelectorAll('.tab-btn');
  const tabContents = document.querySelectorAll('.tab-content');

  tabButtons.forEach((btn) => {
    btn.addEventListener('click', () => {
      tabButtons.forEach((b) => b.classList.remove('active'));
      tabContents.forEach((c) => c.classList.remove('active'));

      btn.classList.add('active');
      const targetId = btn.getAttribute('data-tab');
      const targetContent = document.getElementById(targetId);
      if (targetContent) targetContent.classList.add('active');

      if (targetId === 'tab-customers') loadCustomers();
      if (targetId === 'tab-transfers') loadPendingTransfers();
      if (targetId === 'tab-settings') loadSystemConfigs();
      if (targetId === 'tab-audit') loadAuditLogs();
    });
  });

  
}

function setupEventListeners() {
  document.getElementById('btnSearchCustomers').addEventListener('click', loadCustomers);
  document.getElementById('customerSearchInput').addEventListener('keypress', (e) => {
    if (e.key === 'Enter') loadCustomers();
  });

  document.getElementById('btnRefreshTransfers').addEventListener('click', loadPendingTransfers);
  document.getElementById('btnRefreshLogs').addEventListener('click', loadAuditLogs);
  document.getElementById('btnSaveConfig').addEventListener('click', saveSystemConfigs);

  const modal = document.getElementById('editCustomerModal');
  document.getElementById('btnCancelEdit').addEventListener('click', () => {
    modal.classList.remove('active');
  });

  document.getElementById('editCustomerForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const customerId = document.getElementById('editCustomerId').value;
    const body = {
      businessName: document.getElementById('editBusinessName').value,
      ownerName: document.getElementById('editOwnerName').value,
      mobileNumber: document.getElementById('editMobileNumber').value,
      city: document.getElementById('editCity').value
    };

    try {
      const resp = await fetch(`${apiBaseUrl}/admin/customers/${customerId}`, {
        method: 'PUT',
        headers: await getAuthHeaders(),
        body: JSON.stringify(body)
      });
      const resJson = await resp.json();
      if (resJson.success) {
        modal.classList.remove('active');
        loadCustomers();
        loadAuditLogs();
      } else {
        alert(`Update Failed: ${resJson.error?.message || 'Unknown error'}`);
      }
    } catch (err) {
      alert(`Network Error: ${err.message}`);
    }
  });

  // --- APK Distribution Logic ---
  const apkMethods = document.querySelectorAll('input[name="apkMethod"]');
  apkMethods.forEach(radio => {
    radio.addEventListener('change', (e) => {
      document.getElementById('methodManual').style.display = e.target.value === 'manual' ? 'block' : 'none';
      document.getElementById('methodUpload').style.display = e.target.value === 'upload' ? 'block' : 'none';
    });
  });

  const fileApkUpload = document.getElementById('fileApkUpload');
  if (fileApkUpload) {
    document.getElementById('btnChooseApk').addEventListener('click', () => {
      fileApkUpload.click();
    });
    
    fileApkUpload.addEventListener('change', (e) => {
      const file = e.target.files[0];
      const lbl = document.getElementById('lblSelectedFile');
      if (file) {
        const sizeMb = (file.size / (1024 * 1024)).toFixed(1);
        lbl.textContent = `${file.name} (${sizeMb} MB)`;
      } else {
        lbl.textContent = 'No file selected';
      }
    });

    document.getElementById('btnUploadApk').addEventListener('click', async () => {
      const file = fileApkUpload.files[0];
      if (!file) {
        alert('Please select an APK file first.');
        return;
      }
      if (!file.name.toLowerCase().endsWith('.apk')) {
        alert('Only .apk files are allowed.');
        return;
      }

      const version = document.getElementById('txtLatestAppVersion').value.trim();
      if (!version) {
        alert('Please enter the Latest App Version first (e.g. 1.0.2+3).');
        return;
      }
      
      const currentUrl = document.getElementById('txtApkDownloadUrl').value;
      if (currentUrl && currentUrl.includes(`public/apks/${version}.apk`)) {
        if (!confirm(`Warning: It looks like version ${version} might already exist. Overwrite?`)) {
          return;
        }
      }

      const btn = document.getElementById('btnUploadApk');
      const progressContainer = document.getElementById('uploadProgressContainer');
      const progressBar = document.getElementById('barUploadProgress');
      const percentLbl = document.getElementById('lblUploadPercent');
      const statusLbl = document.getElementById('lblUploadStatus');

      btn.disabled = true;
      btn.textContent = 'Uploading...';
      progressContainer.style.display = 'block';
      progressBar.style.width = '0%';
      percentLbl.textContent = '0%';
      statusLbl.textContent = 'Uploading...';
      statusLbl.style.color = '';

      const chunkSize = 20 * 1024 * 1024; // 20MB
      const totalChunks = Math.ceil(file.size / chunkSize);
      let finalDownloadUrl = '';

      try {
        for (let i = 0; i < totalChunks; i++) {
          const start = i * chunkSize;
          const end = Math.min(start + chunkSize, file.size);
          const chunk = file.slice(start, end);

          const formData = new FormData();
          formData.append('chunk', chunk);
          formData.append('version', version);
          formData.append('chunkIndex', i.toString());
          formData.append('totalChunks', totalChunks.toString());
          formData.append('totalSize', file.size.toString());

          const headers = await getAuthHeaders();
          delete headers['Content-Type'];

          const response = await fetch(`${apiBaseUrl}/admin/upload-apk-chunk`, {
            method: 'POST',
            headers: headers,
            body: formData
          });

          if (!response.ok) {
            const errText = await response.text();
            throw new Error(`Upload failed on chunk ${i + 1}: ${errText}`);
          }

          const resData = await response.json();
          if (!resData.success) {
            throw new Error(resData.error?.message || 'Upload failed');
          }

          if (resData.downloadUrl) {
            finalDownloadUrl = resData.downloadUrl;
          }

          const percent = Math.round(((i + 1) / totalChunks) * 100);
          progressBar.style.width = `${percent}%`;
          percentLbl.textContent = `${percent}%`;
        }

        statusLbl.textContent = 'Upload Complete! Saving configuration...';
        statusLbl.style.color = 'var(--success)';
        
        document.getElementById('txtApkDownloadUrl').value = finalDownloadUrl;
        
        await saveSystemConfigs();
        
        document.querySelector('input[name="apkMethod"][value="manual"]').checked = true;
        document.getElementById('methodManual').style.display = 'block';
        document.getElementById('methodUpload').style.display = 'none';
        
        alert('APK uploaded successfully and configuration updated.');
        fileApkUpload.value = '';
        document.getElementById('lblSelectedFile').textContent = 'No file selected';

      } catch (err) {
        console.error(err);
        statusLbl.textContent = `Error: ${err.message}`;
        statusLbl.style.color = 'var(--error)';
        alert(`Error: ${err.message}`);
      } finally {
        btn.disabled = false;
        btn.textContent = 'Upload & Apply';
        setTimeout(() => { progressContainer.style.display = 'none'; }, 5000);
      }
    });
  }

}

/**
 * Loads Customer 360° Data (`GET /v1/admin/customers`)
 */
async function loadCustomers() {
  const query = document.getElementById('customerSearchInput').value.trim();
  const listContainer = document.getElementById('customersList');
  listContainer.innerHTML = '<div class="loading-state">Querying edge datastore...</div>';

  try {
    const resp = await fetch(`${apiBaseUrl}/admin/customers?query=${encodeURIComponent(query)}`, {
      method: 'GET',
      headers: await getAuthHeaders()
    });
    const resJson = await resp.json();

    if (!resJson.success || !resJson.data?.customers) {
      listContainer.innerHTML = `<div class="loading-state">Error: ${resJson.error?.message || 'Failed to fetch customers'}</div>`;
      return;
    }

    const customers = resJson.data.customers;
    if (customers.length === 0) {
      listContainer.innerHTML = '<div class="loading-state">No matching vendors found.</div>';
      return;
    }

    listContainer.innerHTML = '';
    customers.forEach((cust) => {
      const activeSub = cust.activeSubscription;
      let subBadge = '<span class="badge danger">No Active Plan</span>';
      if (activeSub) {
        let daysLeftText = '';
        if (activeSub.expiresAtEpochMs) {
          const daysLeft = Math.ceil((activeSub.expiresAtEpochMs - Date.now()) / (1000 * 60 * 60 * 24));
          daysLeftText = ` (${daysLeft} days left)`;
        }
        if (activeSub.status === 'CANCELLED') {
          subBadge = `<span class="badge danger">CANCELLED: ${activeSub.planId}</span>`;
        } else if (activeSub.status === 'EXPIRED') {
          subBadge = `<span class="badge warning">EXPIRED: ${activeSub.planId}</span>`;
        } else {
          subBadge = `<span class="badge success">Plan: ${activeSub.planId || 'ACTIVE'}${daysLeftText}</span>`;
        }
      }

      const statusBadge = cust.status === 'DEACTIVATED' 
        ? '<span class="badge danger" style="margin-left: 8px;">DEACTIVATED</span>'
        : '<span class="badge success" style="margin-left: 8px;">ACTIVE</span>';

      const card = document.createElement('div');
      card.className = `customer-card glass ${activeSub ? 'active-sub' : 'expired-sub'} ${cust.status === 'DEACTIVATED' ? 'deactivated' : ''}`;
      card.innerHTML = `
        <div class="card-header">
          <div style="min-width: 0; padding-right: 8px;">
            <h3 style="white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">${cust.businessName || 'Unnamed Business'}</h3>
            <span>ID: ${cust.customerId}</span>
          </div>
          <div style="display: flex; gap: 4px; flex-wrap: wrap; justify-content: flex-end;">
            ${subBadge}
            ${statusBadge}
          </div>
        </div>
        <div class="card-body">
          <div class="info-item" style="min-width: 0;">
            <span class="label">Owner</span>
            <span class="value" style="white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">${cust.ownerName || '—'}</span>
          </div>
          <div class="info-item" style="min-width: 0;">
            <span class="label">Mobile Number</span>
            <span class="value" style="white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">${cust.mobileNumber || '—'}</span>
          </div>
          <div class="info-item" style="min-width: 0;">
            <span class="label">Location</span>
            <span class="value" style="white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">${cust.city || '—'}</span>
          </div>
          <div class="devices-section" style="margin-top: 16px; padding-top: 12px; border-top: 1px solid rgba(255,255,255,0.1); grid-column: 1 / -1;">
            <div class="label" style="margin-bottom: 8px;">Registered Devices & Trials</div>
            ${cust.installations && cust.installations.length > 0 ? cust.installations.map(inst => {
              const trial = (cust.hardwareTrials || []).find(t => t.hardwareId === (inst.hardwareId || inst.installationId));
              let trialStatusHtml = '';
              if (trial) {
                const now = Date.now();
                const isTrialActive = trial.expiresAtEpochMs > now;
                const daysLeft = Math.max(0, Math.ceil((trial.expiresAtEpochMs - now) / 86400000));
                trialStatusHtml = `<div style="font-size: 10px; color: ${isTrialActive ? '#00E676' : '#ff4444'}; margin-top: 2px;">Hardware Trial: ${isTrialActive ? `${daysLeft} Days Left` : 'Expired'}</div>`;
              }
              return `
              <div style="display: flex; justify-content: space-between; align-items: center; background: rgba(0,0,0,0.2); padding: 8px; border-radius: 4px; margin-bottom: 4px; gap: 8px;">
                <div style="flex: 1; min-width: 0;">
                  <div style="font-size: 12px; font-family: monospace; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; cursor: pointer; color: #00D1FF;" onclick="copyHardwareId('${inst.hardwareId || inst.installationId}', this)" title="Click to copy: ${inst.hardwareId || inst.installationId}">📋 ${inst.hardwareId || inst.installationId}</div>
                  <div style="font-size: 11px; color: #888; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">${(inst.deviceModel || inst.platform || 'ANDROID').toUpperCase()} • <span style="color: ${inst.status === 'BANNED' ? '#ff4444' : '#00E676'}">${inst.status || 'ACTIVE'}</span></div>
                  ${trialStatusHtml}
                </div>
                <div style="display: flex; gap: 4px; flex-shrink: 0;">
                  <button class="btn secondary" style="padding: 4px 8px; font-size: 11px; white-space: nowrap;" onclick="copyHardwareId('${inst.hardwareId || inst.installationId}', this)" title="Copy Hardware ID">
                    Copy ID
                  </button>
                  <button class="btn ${inst.status === 'BANNED' ? 'success' : 'danger'}" style="padding: 4px 8px; font-size: 11px; white-space: nowrap;" onclick="toggleDeviceBan('${inst.hardwareId || inst.installationId}', '${inst.status === 'BANNED' ? 'ACTIVE' : 'BANNED'}')">
                    ${inst.status === 'BANNED' ? 'Unblock' : 'Block Device'}
                  </button>
                </div>
              </div>
              `;
            }).join('') : '<div style="font-size: 12px; color: #888;">No hardware bindings</div>'}
          </div>
        </div>
        <div class="card-actions">
          <button class="btn secondary" onclick="openEditCustomer('${cust.customerId}', '${encodeURIComponent(cust.businessName || '')}', '${encodeURIComponent(cust.ownerName || '')}', '${encodeURIComponent(cust.mobileNumber || '')}', '${encodeURIComponent(cust.city || '')}')">Edit Profile</button>
          <button class="btn warning" onclick="openManageSubscription('${cust.customerId}')">Manage Sub</button>
          <button class="btn ${cust.status === 'DEACTIVATED' ? 'primary' : 'danger'}" onclick="toggleCustomerStatus('${cust.customerId}', '${cust.status === 'DEACTIVATED' ? 'ACTIVE' : 'DEACTIVATED'}')">
            ${cust.status === 'DEACTIVATED' ? 'Activate' : 'Deactivate'}
          </button>
        </div>
      `;
      listContainer.appendChild(card);
    });
  } catch (err) {
    listContainer.innerHTML = `<div class="loading-state">Connection Error: ${err.message}</div>`;
  }
}

function openEditCustomer(id, bName, oName, mobile, city) {
  document.getElementById('editCustomerId').value = id;
  document.getElementById('editBusinessName').value = decodeURIComponent(bName);
  document.getElementById('editOwnerName').value = decodeURIComponent(oName);
  document.getElementById('editMobileNumber').value = decodeURIComponent(mobile);
  document.getElementById('editCity').value = decodeURIComponent(city);
  document.getElementById('editCustomerModal').classList.add('active');
}

async function toggleCustomerStatus(customerId, newStatus) {
  if (!confirm(`Are you sure you want to ${newStatus === 'DEACTIVATED' ? 'DEACTIVATE' : 'ACTIVATE'} this customer?`)) return;
  try {
    const resp = await fetch(`${apiBaseUrl}/admin/customers/${customerId}`, {
      method: 'PUT',
      headers: await getAuthHeaders(),
      body: JSON.stringify({ status: newStatus })
    });
    const resJson = await resp.json();
    if (resJson.success) {
      loadCustomers();
      loadAuditLogs();
    } else {
      alert(`Status update failed: ${resJson.error?.message || 'Unknown error'}`);
    }
  } catch (err) {
    alert(`Network Error: ${err.message}`);
  }
}

/**
 * Bans or unbans a specific hardware device
 */
async function toggleDeviceBan(hardwareId, newStatus) {
  const action = newStatus === 'BANNED' ? 'BLOCK' : 'UNBLOCK';
  if (!confirm(`Are you sure you want to ${action} device ${hardwareId}?`)) return;

  try {
    const endpoint = newStatus === 'BANNED' ? 'ban' : 'unban';
    const resp = await fetch(`${apiBaseUrl}/admin/devices/${hardwareId}/${endpoint}`, {
      method: 'PUT',
      headers: await getAuthHeaders()
    });
    const resJson = await resp.json();

    if (resJson.success) {
      loadCustomers();
      loadAuditLogs();
    } else {
      alert(`Device status update failed: ${resJson.error?.message || 'Unknown error'}`);
    }
  } catch (err) {
    alert(`Network Error: ${err.message}`);
  }
}

/**
 * Copies a hardware ID to clipboard with visual feedback
 */
function copyHardwareId(text, el) {
  const showFeedback = () => {
    const originalText = el.innerText || el.textContent;
    el.innerText = 'Copied! ✅';
    const oldColor = el.style.color;
    el.style.color = '#00E676';
    setTimeout(() => {
      el.innerText = originalText;
      el.style.color = oldColor;
    }, 2000);
  };

  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(showFeedback).catch(() => fallbackCopy(text, showFeedback));
  } else {
    fallbackCopy(text, showFeedback);
  }
}

function fallbackCopy(text, onSuccess) {
  const textArea = document.createElement("textarea");
  textArea.value = text;
  textArea.style.position = "fixed";
  textArea.style.left = "-99999px";
  document.body.appendChild(textArea);
  textArea.select();
  try {
    document.execCommand('copy');
    onSuccess();
  } catch (e) {
    alert('Hardware ID: ' + text);
  }
  document.body.removeChild(textArea);
}

/**
 * Loads P2P Transfer Requests (`GET /v1/transfers/pending`)
 */
async function loadPendingTransfers() {
  const tableBody = document.getElementById('transfersTableBody');
  const countBadge = document.getElementById('pendingTransfersCount');
  tableBody.innerHTML = '<tr><td colspan="6" class="empty-cell">Fetching pending transfers...</td></tr>';

  try {
    const resp = await fetch(`${apiBaseUrl}/admin/transfers/pending`, {
      method: 'GET',
      headers: await getAuthHeaders()
    });
    const resJson = await resp.json();

    if (!resJson.success || !resJson.data?.transfers) {
      tableBody.innerHTML = '<tr><td colspan="6" class="empty-cell">Failed to fetch transfer queue.</td></tr>';
      return;
    }

    const transfers = resJson.data.transfers;
    countBadge.innerText = transfers.length;

    if (transfers.length === 0) {
      tableBody.innerHTML = '<tr><td colspan="6" class="empty-cell">No pending device transfer requests.</td></tr>';
      return;
    }

    tableBody.innerHTML = '';
    transfers.forEach((tx) => {
      const row = document.createElement('tr');
      row.innerHTML = `
        <td><strong>${tx.transferId}</strong></td>
        <td>${tx.customerId}</td>
        <td><code style="cursor: pointer; color: #00D1FF;" onclick="copyHardwareId('${tx.sourceHardwareId || tx.oldInstallationId || ''}', this)" title="Click to copy">${tx.sourceHardwareId || tx.oldInstallationId || '—'}</code></td>
        <td><code style="cursor: pointer; color: #00D1FF;" onclick="copyHardwareId('${tx.targetHardwareId || tx.newInstallationId || ''}', this)" title="Click to copy">${tx.targetHardwareId || tx.newInstallationId || '—'}</code></td>
        <td>${new Date(tx.requestedAtEpochMs || Date.now()).toLocaleString()}</td>
        <td>
          <button class="btn success" onclick="approveLostPhoneTransfer('${tx.transferId}')">Approve</button>
          <button class="btn danger" onclick="rejectLostPhoneTransfer('${tx.transferId}')">Reject</button>
        </td>
      `;
      tableBody.appendChild(row);
    });
  } catch (err) {
    tableBody.innerHTML = `<tr><td colspan="6" class="empty-cell">Network error: ${err.message}</td></tr>`;
  }
}

/**
 * Approves a device transfer override (`POST /v1/admin/transfers/:transferId/approve`)
 */
async function approveLostPhoneTransfer(transferId) {
  if (!confirm(`Confirm Lost/Broken Phone Override for transfer ${transferId}? This will immediately revoke the old hardware ID and bind the subscription to the new phone.`)) {
    return;
  }

  try {
    const resp = await fetch(`${apiBaseUrl}/admin/transfers/${transferId}/approve`, {
      method: 'POST',
      headers: await getAuthHeaders()
    });
    const resJson = await resp.json();

    if (resJson.success) {
      alert(`Transfer Approved Successfully! Target device is now active.`);
      loadPendingTransfers();
      loadCustomers();
      loadAuditLogs();
    } else {
      alert(`Approval Error: ${resJson.error?.message || 'Unknown error'}`);
    }
  } catch (err) {
    alert(`Network Error: ${err.message}`);
  }
}

/**
 * Rejects a device transfer override (`POST /v1/admin/transfers/:transferId/reject`)
 */
async function rejectLostPhoneTransfer(transferId) {
  if (!confirm(`Are you sure you want to REJECT transfer ${transferId}?`)) {
    return;
  }

  try {
    const resp = await fetch(`${apiBaseUrl}/admin/transfers/${transferId}/reject`, {
      method: 'POST',
      headers: await getAuthHeaders()
    });
    const resJson = await resp.json();

    if (resJson.success) {
      alert('Transfer rejected successfully.');
      loadPendingTransfers();
      loadAuditLogs();
    } else {
      alert(`Rejection failed: ${resJson.error?.message || 'Unknown error'}`);
    }
  } catch (err) {
    alert(`Network Error: ${err.message}`);
  }
}

/**
 * Loads & Saves System Configs (`PUT /v1/admin/config/system`)
 */
async function loadSystemConfigs() {
  try {
    const resp = await fetch(`${apiBaseUrl}/config/system`, { method: 'GET' });
    const resJson = await resp.json();
    const config = resJson.data || {};

    document.getElementById('chkAllowPayments').checked = config.allowPayments !== false;
    document.getElementById('chkAllowTransfers').checked = config.allowP2PTransfers !== false;
    document.getElementById('chkMaintenanceMode').checked = config.maintenanceMode === true;
    document.getElementById('chkStrictAppVersion').checked = config.enforceStrictAppVersion === true;
    
    document.getElementById('txtLatestAppVersion').value = config.latestVersion || '';
    document.getElementById('txtMinimumAppVersion').value = config.minimumSupportedVersion || '';
    document.getElementById('txtApkDownloadUrl').value = config.apkDownloadUrl || '';

    const currentVersionLabel = document.getElementById('lblCurrentActiveVersion');
    if (currentVersionLabel) {
      if (config.latestVersion) {
        currentVersionLabel.textContent = `(Currently Active: ${config.latestVersion})`;
      } else {
        currentVersionLabel.textContent = '';
      }
    }
  } catch (err) {
    console.warn('Could not inspect initial configs:', err);
  }
}

async function saveSystemConfigs() {
  const body = {
    allowPayments: document.getElementById('chkAllowPayments').checked,
    allowP2PTransfers: document.getElementById('chkAllowTransfers').checked,
    maintenanceMode: document.getElementById('chkMaintenanceMode').checked,
    enforceStrictAppVersion: document.getElementById('chkStrictAppVersion').checked,
    latestAppVersion: document.getElementById('txtLatestAppVersion').value.trim(),
    minimumAppVersion: document.getElementById('txtMinimumAppVersion').value.trim(),
    apkDownloadUrl: document.getElementById('txtApkDownloadUrl').value.trim()
  };

  try {
    const resp = await fetch(`${apiBaseUrl}/admin/config/system`, {
      method: 'PUT',
      headers: await getAuthHeaders(),
      body: JSON.stringify(body)
    });
    const resJson = await resp.json();
    if (resJson.success) {
      alert('Global edge configuration updated and applied.');
      loadAuditLogs();
    } else {
      alert(`Config Error: ${resJson.error?.message || 'Unknown error'}`);
    }
  } catch (err) {
    alert(`Network Error: ${err.message}`);
  }
}

/**
 * Loads Immutable Audit Logs (`GET /v1/admin/audit-logs`)
 */
async function loadAuditLogs() {
  const tableBody = document.getElementById('auditTableBody');
  tableBody.innerHTML = '<tr><td colspan="5" class="empty-cell">Querying immutable logs...</td></tr>';

  try {
    const resp = await fetch(`${apiBaseUrl}/admin/audit-logs`, {
      method: 'GET',
      headers: await getAuthHeaders()
    });
    const resJson = await resp.json();

    if (!resJson.success || !resJson.data?.logs) {
      tableBody.innerHTML = '<tr><td colspan="5" class="empty-cell">Failed to load audit logs.</td></tr>';
      return;
    }

    const logs = resJson.data.logs;
    if (logs.length === 0) {
      tableBody.innerHTML = '<tr><td colspan="5" class="empty-cell">No audit log records recorded yet.</td></tr>';
      return;
    }

    tableBody.innerHTML = '';
    logs.forEach((item) => {
      const row = document.createElement('tr');
      const actionBadge = item.action && item.action.includes('ADMIN')
        ? `<span class="badge warning">${item.action}</span>`
        : `<span class="badge success">${item.action || 'LOG'}</span>`;

      row.innerHTML = `
        <td><code>${item.logId}</code></td>
        <td>${new Date(item.createdAtEpochMs || Date.now()).toLocaleString()}</td>
        <td>${actionBadge}</td>
        <td>${item.severity || 'INFO'}</td>
        <td><code style="font-size:0.75rem;">${JSON.stringify(item.metadata || item.changes || {})}</code></td>
      `;
      tableBody.appendChild(row);
    });
  } catch (err) {
    tableBody.innerHTML = `<tr><td colspan="5" class="empty-cell">Network error: ${err.message}</td></tr>`;
  }
}

/**
 * Loads Subscription Plans (`GET /v1/plans`)
 */
async function loadPlans() {
  try {
    const url = apiBaseUrl.endsWith('/api/v1') ? apiBaseUrl.replace('/api/v1', '/api/v1/plans') : `${apiBaseUrl}/plans`;
    const resp = await fetch(url, {
      method: 'GET'
    });
    const resJson = await resp.json();
    
    if (resJson.success && resJson.data) {
      const monthlyPlan = resJson.data.find(p => p.planId === 'PRO_MONTHLY');
      const yearlyPlan = resJson.data.find(p => p.planId === 'PRO_YEARLY');
      
      if (monthlyPlan) {
        document.getElementById('planPriceMonthly').value = monthlyPlan.amountPaise / 100;
      }
      if (yearlyPlan) {
        document.getElementById('planPriceYearly').value = yearlyPlan.amountPaise / 100;
      }
    }
  } catch (err) {
    console.error('Failed to load plans', err);
  }
}

/**
 * Updates Subscription Plans (`POST /v1/admin/plans`)
 */
async function savePlans(e) {
  e.preventDefault();
  
  const monthlyPrice = parseInt(document.getElementById('planPriceMonthly').value, 10);
  const yearlyPrice = parseInt(document.getElementById('planPriceYearly').value, 10);
  
  if (isNaN(monthlyPrice) || isNaN(yearlyPrice)) {
    alert('Please enter valid numeric prices.');
    return;
  }
  
  const payload = {
    plans: [
      {
        planId: 'PRO_MONTHLY',
        amountPaise: monthlyPrice * 100
      },
      {
        planId: 'PRO_YEARLY',
        amountPaise: yearlyPrice * 100
      }
    ]
  };

  try {
    const resp = await fetch(`${apiBaseUrl}/admin/plans`, {
      method: 'POST',
      headers: await getAuthHeaders(),
      body: JSON.stringify(payload)
    });
    const resJson = await resp.json();
    if (resJson.success) {
      alert('Plan prices successfully updated!');
    } else {
      alert(`Update Error: ${resJson.error?.message || 'Unknown error'}`);
    }
  } catch (err) {
    alert(`Network Error: ${err.message}`);
  }
}

// Event Listeners for Plans
document.getElementById('btnRefreshPlans')?.addEventListener('click', loadPlans);
document.getElementById('plansForm')?.addEventListener('submit', savePlans);

// --- Manage Subscription Modal Logic ---

function openManageSubscription(customerId) {
  document.getElementById('manageSubCustomerId').value = customerId;
  const actionSelect = document.getElementById('manageSubAction');
  actionSelect.value = '';
  actionSelect.dispatchEvent(new Event('change'));
  document.getElementById('manageSubModal').classList.add('active');
}

document.getElementById('btnCancelManageSub')?.addEventListener('click', () => {
  document.getElementById('manageSubModal').classList.remove('active');
});

document.getElementById('manageSubAction')?.addEventListener('change', (e) => {
  const val = e.target.value;
  document.getElementById('manageSubExtendConfig').style.display = val === 'EXTEND' ? 'block' : 'none';
  document.getElementById('manageSubPlanConfig').style.display = val === 'CHANGE_PLAN' ? 'block' : 'none';
  document.getElementById('manageSubTransferConfig').style.display = val === 'TRANSFER' ? 'block' : 'none';
  document.getElementById('manageSubRemoveConfig').style.display = val === 'REMOVE' ? 'block' : 'none';
});

document.getElementById('manageSubForm')?.addEventListener('submit', async (e) => {
  e.preventDefault();
  const customerId = document.getElementById('manageSubCustomerId').value;
  const action = document.getElementById('manageSubAction').value;
  
  if (!action) {
    alert('Please select an action');
    return;
  }
  
  if (action === 'REMOVE') {
    if (!confirm('Are you absolutely sure you want to cancel this subscription? Access will be immediately revoked.')) {
      return;
    }
  }

  const payload = { action };
  if (action === 'EXTEND') {
    const days = parseInt(document.getElementById('manageSubDays').value, 10);
    if (isNaN(days) || days <= 0) return alert('Enter valid number of days');
    payload.daysToAdd = days;
  } else if (action === 'CHANGE_PLAN') {
    payload.newPlanId = document.getElementById('manageSubPlanId').value;
  } else if (action === 'TRANSFER') {
    const hwId = document.getElementById('manageSubNewHardwareId').value.trim();
    if (!hwId) return alert('Enter the new Hardware ID');
    payload.newHardwareId = hwId;
  }

  const submitBtn = document.querySelector('#manageSubForm button[type="submit"]');
  const originalText = submitBtn.textContent;
  submitBtn.disabled = true;
  submitBtn.textContent = 'Processing...';

  try {
    const resp = await fetch(`${apiBaseUrl}/admin/customers/${customerId}/subscription`, {
      method: 'PUT',
      headers: await getAuthHeaders(),
      body: JSON.stringify(payload)
    });
    const resJson = await resp.json();
    if (resJson.success) {
      alert(`Success: ${resJson.message || resJson.data?.message || 'Operation completed successfully'}`);
      document.getElementById('manageSubModal').classList.remove('active');
      loadCustomers();
      loadAuditLogs();
    } else {
      alert(`Update Failed: ${resJson.error?.message || 'Unknown error'}`);
    }
  } catch (err) {
    alert(`Network Error: ${err.message}`);
  } finally {
    submitBtn.disabled = false;
    submitBtn.textContent = originalText;
  }
});

