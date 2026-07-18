/**
 * VendSoft Control Plane — Admin Portal Client Logic (`app.js`)
 * Communicates with Cloudflare Workers `/api/v1/admin/*` endpoints.
 */

let apiBaseUrl = 'https://vendsoft-api-worker.vendorproapk.workers.dev/api/v1';
let adminSecret = ''; // Will be populated by prompt for production
const authHeaders = {
  'x-admin-secret': 'admin_secret_mock', // Default for local dev
  'Content-Type': 'application/json'
};

document.addEventListener('DOMContentLoaded', () => {
  // Prompt for production password on load
  const requirePassword = () => {
    if (apiBaseUrl.includes('vendsoft-api-worker.vendorproapk.workers.dev')) {
      adminSecret = sessionStorage.getItem('vendsoft_admin_secret') || prompt('Enter Admin Password for Production:');
      if (adminSecret) {
        sessionStorage.setItem('vendsoft_admin_secret', adminSecret);
        authHeaders['x-admin-secret'] = adminSecret;
      }
    } else {
      authHeaders['x-admin-secret'] = 'admin_secret_mock';
    }
  };

  // Sync API URL from dropdown
  const urlSelect = document.getElementById('apiBaseUrl');
  if (urlSelect) {
    apiBaseUrl = urlSelect.value;
    requirePassword();
    
    urlSelect.addEventListener('change', (e) => {
      apiBaseUrl = e.target.value;
      requirePassword();
      document.getElementById('adminStatusText').textContent = apiBaseUrl.includes('127.0.0.1') ? 'Auth: Dev Mock (admin_secret_mock)' : 'Auth: Production Secret';
      // Reload all data for the new target
      loadCustomers();
      loadPendingTransfers();
      loadSystemConfigs();
      loadAuditLogs();
      loadPlans();
    });
  } else {
    requirePassword();
  }
  setupNavigation();
  setupEventListeners();
  loadCustomers();
  loadPendingTransfers();
  loadSystemConfigs();
  loadAuditLogs();
  loadPlans();
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

  const apiSelect = document.getElementById('apiBaseUrl');
  apiSelect.addEventListener('change', (e) => {
    apiBaseUrl = e.target.value;
    loadCustomers();
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
        headers: authHeaders,
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
      headers: authHeaders
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
      const subBadge = activeSub 
        ? `<span class="badge success">Plan: ${activeSub.planId || 'ACTIVE'}</span>` 
        : '<span class="badge danger">No Active Plan</span>';

      const statusBadge = cust.status === 'DEACTIVATED' 
        ? '<span class="badge danger" style="margin-left: 8px;">DEACTIVATED</span>'
        : '<span class="badge success" style="margin-left: 8px;">ACTIVE</span>';

      const card = document.createElement('div');
      card.className = `customer-card glass ${activeSub ? 'active-sub' : 'expired-sub'} ${cust.status === 'DEACTIVATED' ? 'deactivated' : ''}`;
      card.innerHTML = `
        <div class="card-header">
          <div>
            <h3>${cust.businessName || 'Unnamed Business'}</h3>
            <span>ID: ${cust.customerId}</span>
          </div>
          <div style="display: flex; gap: 4px;">
            ${subBadge}
            ${statusBadge}
          </div>
        </div>
        <div class="card-body">
          <div class="info-item">
            <span class="label">Owner</span>
            <span class="value">${cust.ownerName || '—'}</span>
          </div>
          <div class="info-item">
            <span class="label">Mobile Number</span>
            <span class="value">${cust.mobileNumber || '—'}</span>
          </div>
          <div class="info-item">
            <span class="label">Location</span>
            <span class="value">${cust.city || '—'}</span>
          </div>
          <div class="devices-section" style="margin-top: 16px; padding-top: 12px; border-top: 1px solid rgba(255,255,255,0.1);">
            <div class="label" style="margin-bottom: 8px;">Registered Devices</div>
            ${cust.installations && cust.installations.length > 0 ? cust.installations.map(inst => `
              <div style="display: flex; justify-content: space-between; align-items: center; background: rgba(0,0,0,0.2); padding: 8px; border-radius: 4px; margin-bottom: 4px;">
                <div>
                  <div style="font-size: 12px; font-family: monospace;">${inst.hardwareId || inst.installationId}</div>
                  <div style="font-size: 11px; color: #888;">${(inst.platform || 'ANDROID').toUpperCase()} • <span style="color: ${inst.status === 'BANNED' ? '#ff4444' : '#00E676'}">${inst.status || 'ACTIVE'}</span></div>
                </div>
                <button class="btn ${inst.status === 'BANNED' ? 'success' : 'danger'}" style="padding: 4px 8px; font-size: 11px;" onclick="toggleDeviceBan('${inst.hardwareId || inst.installationId}', '${inst.status === 'BANNED' ? 'ACTIVE' : 'BANNED'}')">
                  ${inst.status === 'BANNED' ? 'Unblock' : 'Block Device'}
                </button>
              </div>
            `).join('') : '<div style="font-size: 12px; color: #888;">No hardware bindings</div>'}
          </div>
        </div>
        <div class="card-actions">
          <button class="btn secondary" onclick="openEditCustomer('${cust.customerId}', '${encodeURIComponent(cust.businessName || '')}', '${encodeURIComponent(cust.ownerName || '')}', '${encodeURIComponent(cust.mobileNumber || '')}', '${encodeURIComponent(cust.city || '')}')">Edit Profile</button>
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
      headers: authHeaders,
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
      headers: authHeaders
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
 * Loads P2P Transfer Requests (`GET /v1/transfers/pending`)
 */
async function loadPendingTransfers() {
  const tableBody = document.getElementById('transfersTableBody');
  const countBadge = document.getElementById('pendingTransfersCount');
  tableBody.innerHTML = '<tr><td colspan="6" class="empty-cell">Fetching pending transfers...</td></tr>';

  try {
    const resp = await fetch(`${apiBaseUrl}/admin/transfers/pending`, {
      method: 'GET',
      headers: authHeaders
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
        <td><code>${tx.sourceHardwareId || tx.oldInstallationId || '—'}</code></td>
        <td><code>${tx.targetHardwareId || tx.newInstallationId || '—'}</code></td>
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
      headers: authHeaders
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
      headers: authHeaders
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
  } catch (err) {
    console.warn('Could not inspect initial configs:', err);
  }
}

async function saveSystemConfigs() {
  const body = {
    allowPayments: document.getElementById('chkAllowPayments').checked,
    allowP2PTransfers: document.getElementById('chkAllowTransfers').checked,
    maintenanceMode: document.getElementById('chkMaintenanceMode').checked,
    enforceStrictAppVersion: document.getElementById('chkStrictAppVersion').checked
  };

  try {
    const resp = await fetch(`${apiBaseUrl}/admin/config/system`, {
      method: 'PUT',
      headers: authHeaders,
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
      headers: authHeaders
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
      headers: authHeaders,
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

