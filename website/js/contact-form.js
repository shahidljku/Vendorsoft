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
      var submitBtn = form.querySelector('button[type="submit"]');
      var originalBtnText = submitBtn ? submitBtn.textContent : 'Send Message';
      if (submitBtn) {
        submitBtn.textContent = 'Sending...';
        submitBtn.disabled = true;
      }

      var formData = new FormData(form);
      var object = {};
      formData.forEach(function(value, key){
          object[key] = value;
      });
      var json = JSON.stringify(object);

      fetch('https://api.web3forms.com/submit', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
        body: json
      })
      .then(function(response) {
        return response.json();
      })
      .then(function(json) {
        if (json.success) {
          var successMsg = document.getElementById('contactSuccess');
          if (successMsg) {
            form.style.display = 'none';
            successMsg.style.display = 'block';
          }
        } else {
          alert('Something went wrong. Please try again.');
          if (submitBtn) {
            submitBtn.textContent = originalBtnText;
            submitBtn.disabled = false;
          }
        }
      })
      .catch(function(error) {
        console.error('Error submitting form:', error);
        alert('A network error occurred. Please try again.');
        if (submitBtn) {
          submitBtn.textContent = originalBtnText;
          submitBtn.disabled = false;
        }
      });
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
