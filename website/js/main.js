/**
 * VendorPro Website — Main JavaScript
 * Navigation, scroll behavior, and shared utilities.
 * No external dependencies.
 */

(function () {
  'use strict';

  // ── Navigation ──
  var nav = document.getElementById('mainNav');
  var navToggle = document.getElementById('navToggle');
  var navLinks = document.getElementById('navLinks');

  if (navToggle && navLinks) {
    navToggle.addEventListener('click', function () {
      var isOpen = navLinks.classList.toggle('nav__links--open');
      navToggle.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
    });

    // Close mobile nav when a link is clicked
    var links = navLinks.querySelectorAll('.nav__link');
    for (var i = 0; i < links.length; i++) {
      links[i].addEventListener('click', function () {
        navLinks.classList.remove('nav__links--open');
        navToggle.setAttribute('aria-expanded', 'false');
      });
    }
  }

  // ── Scroll shadow on nav ──
  function handleScroll() {
    if (!nav) return;
    if (window.scrollY > 10) {
      nav.classList.add('nav--scrolled');
    } else {
      nav.classList.remove('nav--scrolled');
    }
  }

  window.addEventListener('scroll', handleScroll, { passive: true });
  handleScroll();

  // ── FAQ Accordion ──
  var faqItems = document.querySelectorAll('.faq-item__question');
  for (var j = 0; j < faqItems.length; j++) {
    faqItems[j].addEventListener('click', function () {
      var parent = this.parentElement;
      var isOpen = parent.classList.contains('faq-item--open');

      // Close all others
      var allItems = document.querySelectorAll('.faq-item');
      for (var k = 0; k < allItems.length; k++) {
        allItems[k].classList.remove('faq-item--open');
        var btn = allItems[k].querySelector('.faq-item__question');
        if (btn) btn.setAttribute('aria-expanded', 'false');
      }

      // Toggle current
      if (!isOpen) {
        parent.classList.add('faq-item--open');
        this.setAttribute('aria-expanded', 'true');
      }
    });
  }

  // ── Smooth scroll for anchor links ──
  var anchorLinks = document.querySelectorAll('a[href^="#"]');
  for (var m = 0; m < anchorLinks.length; m++) {
    anchorLinks[m].addEventListener('click', function (e) {
      var targetId = this.getAttribute('href');
      if (targetId === '#') return;
      var target = document.querySelector(targetId);
      if (target) {
        e.preventDefault();
        var navHeight = nav ? nav.offsetHeight : 0;
        var targetTop = target.getBoundingClientRect().top + window.pageYOffset - navHeight - 16;
        window.scrollTo({ top: targetTop, behavior: 'smooth' });
      }
    });
  }

  // ── Current year in footer ──
  var yearElements = document.querySelectorAll('.footer__copyright');
  for (var n = 0; n < yearElements.length; n++) {
    var text = yearElements[n].textContent;
    yearElements[n].textContent = text.replace(/\d{4}/, new Date().getFullYear());
  }
  // ── Dynamic App Download ──
  function initDynamicDownload() {
    var downloadBtns = [];
    var links = document.querySelectorAll('a');
    for (var i = 0; i < links.length; i++) {
      if (links[i].textContent.trim() === 'Download App') {
        downloadBtns.push(links[i]);
      }
    }
    if (downloadBtns.length === 0) return;

    var versionDisplays = document.querySelectorAll('.app-version-display');

    // Set initial loading state
    for (var j = 0; j < downloadBtns.length; j++) {
      downloadBtns[j].textContent = 'Loading...';
      downloadBtns[j].style.pointerEvents = 'none';
      downloadBtns[j].style.opacity = '0.7';
    }
    for (var k = 0; k < versionDisplays.length; k++) {
      versionDisplays[k].textContent = 'Fetching version...';
    }

    var cacheKey = 'vendorpro_app_config';
    var cachedData = sessionStorage.getItem(cacheKey);

    function applyConfig(data) {
      if (!data || !data.apkDownloadUrl || typeof data.apkDownloadUrl !== 'string' || !data.apkDownloadUrl.startsWith('https://')) {
        handleError(new Error('Invalid or missing APK URL from configuration.'));
        return;
      }
      
      for (var j = 0; j < downloadBtns.length; j++) {
        var btn = downloadBtns[j];
        // Clone to remove previous event listeners (like the smooth scroll anchor click)
        var newClone = btn.cloneNode(true);
        newClone.textContent = 'Download App';
        newClone.href = '#'; // Handle redirect via JS for UX
        newClone.style.pointerEvents = 'auto';
        newClone.style.opacity = '1';
        
        newClone.addEventListener('click', function(e) {
          e.preventDefault();
          var self = this;
          var originalText = self.textContent;
          self.textContent = 'Preparing your download...';
          self.style.pointerEvents = 'none';
          
          setTimeout(function() {
            window.open(data.apkDownloadUrl, '_blank', 'noopener,noreferrer');
            setTimeout(function() {
              self.textContent = originalText;
              self.style.pointerEvents = 'auto';
            }, 1000);
          }, 1500);
        });
        
        btn.parentNode.replaceChild(newClone, btn);
      }

      for (var m = 0; m < versionDisplays.length; m++) {
        versionDisplays[m].textContent = 'Latest Version: ' + (data.latestVersion || 'Available');
      }

      // Populate extra metadata defensively
      if (data.fileSize) {
        var sizeEls = document.querySelectorAll('.app-meta-size');
        for (var n = 0; n < sizeEls.length; n++) {
          sizeEls[n].textContent = data.fileSize;
          sizeEls[n].style.display = 'inline-block';
        }
      }
      if (data.updatedAtEpochMs || data.releaseDate) {
        var dateEls = document.querySelectorAll('.app-meta-date');
        var rDate = data.releaseDate;
        if (!rDate && data.updatedAtEpochMs) {
          rDate = new Date(data.updatedAtEpochMs).toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' });
        }
        for (var p = 0; p < dateEls.length; p++) {
          dateEls[p].textContent = rDate;
          dateEls[p].style.display = 'inline-block';
        }
      }
      if (data.releaseNotes) {
        var notesEls = document.querySelectorAll('.app-meta-notes');
        for (var q = 0; q < notesEls.length; q++) {
          notesEls[q].textContent = "What's new: " + data.releaseNotes;
          notesEls[q].style.display = 'block';
        }
      }
      if (data.checksum) {
        var hashEls = document.querySelectorAll('.app-meta-checksum');
        for (var r = 0; r < hashEls.length; r++) {
          hashEls[r].textContent = 'SHA256: ' + data.checksum;
          hashEls[r].style.display = 'block';
        }
      }
    }

    function handleError(err) {
      if (err) console.error('VendorPro Update System API Error:', err);
      // We do NOT want to fetch from DOM again because we might have cloned nodes, 
      // but in error state it's before cloning, so downloadBtns are still in DOM.
      for (var j = 0; j < downloadBtns.length; j++) {
        downloadBtns[j].textContent = 'Download Unavailable';
        downloadBtns[j].style.pointerEvents = 'none'; // Ensure it stays disabled
      }
      for (var k = 0; k < versionDisplays.length; k++) {
        versionDisplays[k].textContent = 'Check back later.';
      }
    }

    if (cachedData) {
      try {
        var parsed = JSON.parse(cachedData);
        applyConfig(parsed);
        return;
      } catch(e) {}
    }

    fetch('https://vendsoft-api-worker.vendorproapk.workers.dev/api/v1/config/system')
      .then(function(res) {
        if (!res.ok) throw new Error('Network response was not ok');
        return res.json();
      })
      .then(function(json) {
        if (json.success && json.data) {
          sessionStorage.setItem(cacheKey, JSON.stringify(json.data));
          applyConfig(json.data);
        } else {
          throw new Error('Invalid API response structure');
        }
      })
      .catch(handleError);
  }

  initDynamicDownload();

})();
