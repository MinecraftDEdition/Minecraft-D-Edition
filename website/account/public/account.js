const loading = document.querySelector('#loading');
const signedOut = document.querySelector('#signed-out');
const dashboard = document.querySelector('#dashboard');
const message = document.querySelector('#message');
let csrfToken = '';

function showMessage(text, isError = false) {
  message.textContent = text;
  message.classList.toggle('error', isError);
  message.hidden = !text;
  if (text) message.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

async function request(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: { ...(options.headers || {}), ...(csrfToken ? { 'X-CSRF-Token': csrfToken } : {}) }
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(result.error || 'The account service could not complete that request.');
  return result;
}

async function loadAccount() {
  const search = new URLSearchParams(location.search);
  if (search.has('error')) {
    showMessage(search.get('error'), true);
    history.replaceState({}, '', '/');
  }
  try {
    const result = await request('/api/me');
    csrfToken = result.csrfToken;
    const account = result.account;
    document.querySelector('#delete-control').hidden = !result.features?.accountDeletion;
    document.querySelector('#account-id').textContent = account.id;
    document.querySelector('#account-email').textContent = account.email;
    document.querySelector('#email-status').textContent = account.emailVerified ? 'Email verified' : 'Email verification needed';
    document.querySelector('#display-name').textContent = account.username || 'Player profile';
    document.querySelector('#username').value = account.username || '';
    document.querySelector(`input[name="model"][value="${account.skinModel}"]`).checked = true;
    if (account.skinUrl) {
      const preview = document.querySelector('#skin-preview');
      preview.src = account.skinUrl;
      preview.hidden = false;
      document.querySelector('#skin-placeholder').hidden = true;
    }
    setAccountActivity(account.active);
    dashboard.hidden = false;
  } catch (error) {
    if (!String(error.message).includes('Sign in') && !String(error.message).includes('request')) showMessage(error.message, true);
    signedOut.hidden = false;
  } finally {
    loading.hidden = true;
  }
}

function setAccountActivity(active) {
  document.querySelector('#inactive-notice').hidden = active;
  document.querySelector('#deactivate-control').hidden = !active;
  document.querySelectorAll('.profile-control').forEach((panel) => { panel.hidden = !active; });
}

document.querySelector('#username-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = event.currentTarget.querySelector('button');
  button.disabled = true;
  try {
    const username = document.querySelector('#username').value;
    const result = await request('/api/profile', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username })
    });
    document.querySelector('#display-name').textContent = result.username;
    showMessage('Username saved.');
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    button.disabled = false;
  }
});

document.querySelector('#skin-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = event.currentTarget.querySelector('button');
  button.disabled = true;
  try {
    const form = new FormData(event.currentTarget);
    const result = await request('/api/skin', { method: 'POST', body: form });
    const preview = document.querySelector('#skin-preview');
    preview.src = result.skinUrl;
    preview.hidden = false;
    document.querySelector('#skin-placeholder').hidden = true;
    showMessage('Skin uploaded.');
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    button.disabled = false;
  }
});

document.querySelector('#password-reset-button').addEventListener('click', async (event) => {
  const button = event.currentTarget;
  button.disabled = true;
  try {
    const result = await request('/api/password/reset', { method: 'POST' });
    showMessage(result.message || 'Check your email for a password reset link.');
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    button.disabled = false;
  }
});

document.querySelector('#deactivate-button').addEventListener('click', async (event) => {
  if (!confirm('Deactivate your MCDE account? You can reactivate it after signing in again.')) return;
  const button = event.currentTarget;
  button.disabled = true;
  try {
    await request('/api/account/deactivate', { method: 'POST' });
    setAccountActivity(false);
    showMessage('Account deactivated. Your profile data has been preserved.');
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    button.disabled = false;
  }
});

document.querySelector('#reactivate-button').addEventListener('click', async (event) => {
  const button = event.currentTarget;
  button.disabled = true;
  try {
    await request('/api/account/reactivate', { method: 'POST' });
    setAccountActivity(true);
    showMessage('Account reactivated.');
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    button.disabled = false;
  }
});

document.querySelector('#delete-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const confirmation = document.querySelector('#delete-confirmation').value;
  if (confirmation !== 'DELETE') {
    showMessage('Type DELETE exactly to permanently delete this account.', true);
    return;
  }
  if (!confirm('Permanently delete this account and all of its MCDE profile data? This cannot be undone.')) return;
  const button = event.currentTarget.querySelector('button');
  button.disabled = true;
  try {
    const result = await request('/api/account/delete', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ confirmation })
    });
    location.assign(result.logoutUrl);
  } catch (error) {
    showMessage(error.message, true);
    button.disabled = false;
  }
});

const query = new URLSearchParams(location.search);
if (query.get('deleted') === '1') {
  showMessage('Your account and profile data were permanently deleted.');
  history.replaceState({}, '', '/');
}

loadAccount();
