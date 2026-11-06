const themeButton = document.querySelector('.mode');

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  themeButton.textContent = theme === 'dark' ? 'Light mode' : 'Dark mode';
}

let savedTheme;
try {
  savedTheme = localStorage.getItem('moving-site-theme');
} catch {
  // The theme remains usable without browser storage.
}
applyTheme(savedTheme === 'light' ? 'light' : 'dark');
themeButton.hidden = false;

themeButton.addEventListener('click', () => {
  const theme = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  applyTheme(theme);
  try {
    localStorage.setItem('moving-site-theme', theme);
  } catch {
    // Keep the current page's theme.
  }
});
