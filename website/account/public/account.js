const loading = document.querySelector('#loading');
const signedOut = document.querySelector('#signed-out');
const dashboard = document.querySelector('#dashboard');
const message = document.querySelector('#message');
let csrfToken = '';
let skinPreviewUrl = '';

function selectedSkinModel() {
  return document.querySelector('input[name="model"]:checked')?.value === 'slim' ? 'slim' : 'classic';
}

function drawSkinPreview(image, model) {
  const canvas = document.querySelector('#skin-preview');
  const context = canvas.getContext('2d');
  const slim = model === 'slim';
  const scale = 6;
  const armWidth = slim ? 3 : 4;
  const bodyX = (canvas.width - 8 * scale) / 2;
  const armY = 8 * scale + (slim ? scale / 2 : 0);
  const rightArmX = bodyX - armWidth * scale;
  const leftArmX = bodyX + 8 * scale;
  context.clearRect(0, 0, canvas.width, canvas.height);
  context.imageSmoothingEnabled = false;
  const part = (sx, sy, sw, sh, x, y, w = sw, h = sh) => {
    context.drawImage(image, sx, sy, sw, sh, x, y, w * scale, h * scale);
  };

  // Front-facing Java skin UVs. Slim deliberately samples the first three
  // front-arm pixels, so an ordinary Classic 64x64 texture is still usable.
  part(44, 20, armWidth, 12, rightArmX, armY);
  part(44, 36, armWidth, 12, rightArmX, armY);
  part(36, 52, armWidth, 12, leftArmX, armY);
  part(52, 52, armWidth, 12, leftArmX, armY);
  part(4, 20, 4, 12, bodyX, 20 * scale);
  part(4, 36, 4, 12, bodyX, 20 * scale);
  part(20, 52, 4, 12, bodyX + 4 * scale, 20 * scale);
  part(4, 52, 4, 12, bodyX + 4 * scale, 20 * scale);
  part(20, 20, 8, 12, bodyX, 8 * scale);
  part(20, 36, 8, 12, bodyX, 8 * scale);
  part(8, 8, 8, 8, bodyX, 0);
  part(40, 8, 8, 8, bodyX, 0);
  canvas.hidden = false;
  document.querySelector('#skin-placeholder').hidden = true;
}

function renderSkinPreview(url, model = selectedSkinModel()) {
  if (!url) return;
  skinPreviewUrl = url;
  const image = new Image();
  image.onload = () => drawSkinPreview(image, model);
  image.src = url;
}

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
    const model = account.skinModel === 'slim' ? 'slim' : 'classic';
    document.querySelector(`input[name="model"][value="${model}"]`).checked = true;
    if (account.skinUrl) {
      renderSkinPreview(account.skinUrl, model);
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
  const button = event.currentTarget.querySelector('button[type="submit"]');
  button.disabled = true;
  try {
    const form = new FormData(event.currentTarget);
    const result = await request('/api/skin', { method: 'POST', body: form });
    renderSkinPreview(result.skinUrl, result.skinModel);
    showMessage('Skin uploaded.');
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    button.disabled = false;
  }
});

document.querySelectorAll('input[name="model"]').forEach((input) => {
  input.addEventListener('change', () => {
    if (skinPreviewUrl) renderSkinPreview(skinPreviewUrl);
  });
});

document.querySelector('#save-model-button').addEventListener('click', async (event) => {
  const button = event.currentTarget;
  button.disabled = true;
  try {
    const result = await request('/api/profile', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ skinModel: selectedSkinModel() })
    });
    if (skinPreviewUrl) renderSkinPreview(skinPreviewUrl, result.skinModel);
    showMessage(`${result.skinModel === 'slim' ? 'Slim' : 'Classic'} arms saved.`);
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
