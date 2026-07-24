/**
 * VendorPro Website — Dynamic Pricing
 * Fetches live pricing from Cloudflare Workers API (GET /api/v1/plans).
 * Implements loading, success, error, retry, and empty states.
 * No external dependencies.
 */

(function () {
  'use strict';

  var API_URL = 'https://vendsoft-api-worker.vendorproapk.workers.dev/api/v1/plans';

  var loadingEl = document.getElementById('pricingLoading');
  var gridEl = document.getElementById('pricingGrid');
  var errorEl = document.getElementById('pricingError');
  var emptyEl = document.getElementById('pricingEmpty');
  var retryBtn = document.getElementById('pricingRetry');

  if (!gridEl) return; // Not on a page with pricing

  function showState(state) {
    if (loadingEl) loadingEl.style.display = state === 'loading' ? '' : 'none';
    gridEl.style.display = state === 'success' ? '' : 'none';
    if (errorEl) errorEl.style.display = state === 'error' ? '' : 'none';
    if (emptyEl) emptyEl.style.display = state === 'empty' ? '' : 'none';
  }

  function formatPrice(paise) {
    var rupees = Math.round(paise / 100);
    return '₹' + rupees.toLocaleString('en-IN');
  }

  function getDurationLabel(plan) {
    var days = plan.durationDays;
    if (days === undefined) {
      if (plan.planId && plan.planId.indexOf('YEARLY') !== -1) days = 365;
      else if (plan.planId && plan.planId.indexOf('MONTHLY') !== -1) days = 30;
    }
    if (days === 365 || days === 366) return '/year';
    if (days === 30 || days === 31) return '/month';
    return days ? '/' + days + ' days' : '';
  }

  function renderPlans(plans) {
    gridEl.innerHTML = '';

    // Sort: recommended first, then by price descending
    plans.sort(function (a, b) {
      if (a.isRecommended && !b.isRecommended) return -1;
      if (!a.isRecommended && b.isRecommended) return 1;
      return (b.amountPaise || 0) - (a.amountPaise || 0);
    });

    for (var i = 0; i < plans.length; i++) {
      var plan = plans[i];

      // Skip free/demo/trial plans — only show paid plans
      if (plan.planId === 'FREE_TRIAL_30' || plan.planId === 'DEMO_FREE') continue;

      var isRecommended = plan.isRecommended === true;
      var price = plan.amountPaise || plan.priceInr * 100 || 0;
      var name = plan.name || plan.planName || plan.planId;
      var description = plan.description || '';
      var features = plan.features || [];

      var card = document.createElement('div');
      card.className = 'pricing-card' + (isRecommended ? ' pricing-card--recommended' : '');
      card.setAttribute('role', 'listitem');

      var html = '';

      if (isRecommended) {
        html += '<div class="pricing-card__badge">Recommended</div>';
      }

      html += '<h3 class="pricing-card__name">' + escapeHtml(name) + '</h3>';
      html += '<div class="pricing-card__price">' + formatPrice(price) + '<span>' + getDurationLabel(plan) + '</span></div>';

      if (description) {
        html += '<p class="pricing-card__desc">' + escapeHtml(description) + '</p>';
      }

      if (features.length > 0) {
        html += '<ul class="pricing-card__features">';
        for (var j = 0; j < features.length; j++) {
          html += '<li>' + escapeHtml(features[j]) + '</li>';
        }
        html += '</ul>';
      }

      html += '<a href="#" class="btn ' + (isRecommended ? 'btn--accent' : 'btn--primary') + '" onclick="return false;">Download App</a>';

      card.innerHTML = html;
      gridEl.appendChild(card);
    }
  }

  function escapeHtml(text) {
    var div = document.createElement('div');
    div.appendChild(document.createTextNode(text));
    return div.innerHTML;
  }

  function fetchPlans() {
    showState('loading');

    var xhr = new XMLHttpRequest();
    xhr.open('GET', API_URL, true);
    xhr.timeout = 15000;

    xhr.onload = function () {
      try {
        var response = JSON.parse(xhr.responseText);
        if (response.success && response.data) {
          var plans = Array.isArray(response.data) ? response.data : (response.data.plans || []);

          // Filter to only active plans
          var activePlans = [];
          for (var i = 0; i < plans.length; i++) {
            if (plans[i].isActive !== false && plans[i].planId !== 'FREE_TRIAL_30' && plans[i].planId !== 'DEMO_FREE') {
              activePlans.push(plans[i]);
            }
          }

          if (activePlans.length === 0) {
            showState('empty');
          } else {
            renderPlans(activePlans);
            showState('success');
          }
        } else {
          showState('error');
        }
      } catch (e) {
        showState('error');
      }
    };

    xhr.onerror = function () {
      showState('error');
    };

    xhr.ontimeout = function () {
      showState('error');
    };

    xhr.send();
  }

  // Retry button
  if (retryBtn) {
    retryBtn.addEventListener('click', fetchPlans);
  }

  // Initial fetch
  fetchPlans();

})();
