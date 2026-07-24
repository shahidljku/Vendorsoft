/**
 * VendorPro Website — Contact Form Validation
 * Client-side validation for the contact form.
 * No external dependencies. No actual form submission endpoint.
 */

(function () {
  'use strict';

  var form = document.getElementById('contactForm');
  if (!form) return;

  form.addEventListener('submit', function (e) {
    e.preventDefault();

    var isValid = true;

    // Clear previous errors
    var groups = form.querySelectorAll('.form-group');
    for (var i = 0; i < groups.length; i++) {
      groups[i].classList.remove('form-group--error');
    }

    // Validate name
    var nameField = document.getElementById('contactName');
    if (nameField && nameField.value.trim().length < 2) {
      setError(nameField, 'Please enter your name.');
      isValid = false;
    }

    // Validate email
    var emailField = document.getElementById('contactEmail');
    if (emailField) {
      var emailVal = emailField.value.trim();
      var emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
      if (!emailRegex.test(emailVal)) {
        setError(emailField, 'Please enter a valid email address.');
        isValid = false;
      }
    }

    // Validate message
    var messageField = document.getElementById('contactMessage');
    if (messageField && messageField.value.trim().length < 10) {
      setError(messageField, 'Please enter a message (at least 10 characters).');
      isValid = false;
    }

    if (isValid) {
      // Show success state (no backend form handler configured)
      var successMsg = document.getElementById('contactSuccess');
      if (successMsg) {
        form.style.display = 'none';
        successMsg.style.display = 'block';
      }
    }
  });

  function setError(field, message) {
    var group = field.closest('.form-group');
    if (group) {
      group.classList.add('form-group--error');
      var errorEl = group.querySelector('.form-error');
      if (errorEl) errorEl.textContent = message;
    }
  }

})();
