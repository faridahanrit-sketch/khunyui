const BANNER_SRC = 'assets/jele-shop-banner.png';
const BANNER_ALT = 'ป้ายร้านเจ๊เล่ส้มตำ รูปแม่พร้อมอาหารตามสั่ง ยำ และส้มตำ';

export function bannerMarkup() {
  return '<figure class="shop-banner"><button class="shop-banner-open" type="button" data-action="shop-banner" aria-label="ดูป้ายร้านเจ๊เล่ส้มตำเต็มภาพ"><img class="shop-banner-image" src="' + BANNER_SRC + '" width="1942" height="809" alt="' + BANNER_ALT + '" decoding="async"><span class="shop-banner-badge">ดูป้ายเต็ม</span></button></figure>';
}

export function initBannerViewer() {
  if (document.getElementById('shopBannerViewer')) return;
  const dialog = document.createElement('dialog');
  dialog.id = 'shopBannerViewer';
  dialog.className = 'shop-banner-viewer';
  dialog.setAttribute('aria-labelledby', 'shopBannerTitle');
  dialog.innerHTML = [
    '<div class="banner-viewer-head"><div><h2 id="shopBannerTitle">ป้ายร้านเจ๊เล่ส้มตำ</h2><p>อาหารตามสั่ง · ยำ · ส้มตำ</p></div><button type="button" class="banner-viewer-close" data-banner-control="close" aria-label="ปิดภาพป้าย">ปิด</button></div>',
    '<div class="banner-viewer-viewport" tabindex="0" role="region" aria-label="ภาพป้ายร้าน เลื่อนดูได้เมื่อขยาย"><div class="banner-viewer-canvas"><img class="banner-viewer-image" alt="' + BANNER_ALT + '" draggable="false"></div></div>',
    '<p class="banner-viewer-error" role="alert" hidden>ยังเปิดภาพป้ายไม่ได้ กรุณาลองอีกครั้ง</p>',
    '<div class="banner-viewer-tools"><div class="banner-zoom-controls" role="group" aria-label="ขยายภาพป้าย"><button type="button" data-banner-control="minus" aria-label="ย่อภาพ" disabled>−</button><output class="banner-zoom-label" aria-live="polite">พอดีจอ</output><button type="button" data-banner-control="plus" aria-label="ขยายภาพ" disabled>+</button><button type="button" data-banner-control="fit">พอดีจอ</button></div><a class="banner-original-link" href="' + BANNER_SRC + '" target="_blank" rel="noopener">เปิดภาพต้นฉบับ</a></div>'
  ].join('');
  document.body.append(dialog);

  const viewport = dialog.querySelector('.banner-viewer-viewport');
  const canvas = dialog.querySelector('.banner-viewer-canvas');
  const image = dialog.querySelector('.banner-viewer-image');
  const error = dialog.querySelector('.banner-viewer-error');
  const output = dialog.querySelector('output');
  const minus = dialog.querySelector('[data-banner-control="minus"]');
  const plus = dialog.querySelector('[data-banner-control="plus"]');
  let zoom = 1;
  let opener = null;

  function applyZoom(value, center = false) {
    if (!image.naturalWidth || !dialog.open) return;
    const vw = viewport.clientWidth;
    const vh = viewport.clientHeight;
    if (vw < 1 || vh < 1) return;
    const ratioX = (viewport.scrollLeft + vw / 2) / Math.max(canvas.offsetWidth, vw);
    const ratioY = (viewport.scrollTop + vh / 2) / Math.max(canvas.offsetHeight, vh);
    zoom = Math.max(1, Math.min(4, value));
    const fit = Math.min(Math.max(1, vw - 24) / image.naturalWidth, Math.max(1, vh - 24) / image.naturalHeight, 1);
    const w = Math.max(1, Math.round(image.naturalWidth * fit * zoom));
    const h = Math.max(1, Math.round(image.naturalHeight * fit * zoom));
    const cw = Math.max(vw, w + 24);
    const ch = Math.max(vh, h + 24);
    canvas.style.width = cw + 'px';
    canvas.style.height = ch + 'px';
    image.style.width = w + 'px';
    image.style.height = h + 'px';
    viewport.scrollLeft = Math.max(0, (center ? cw / 2 : ratioX * cw) - vw / 2);
    viewport.scrollTop = Math.max(0, (center ? ch / 2 : ratioY * ch) - vh / 2);
    output.textContent = zoom === 1 ? 'พอดีจอ' : Math.round(zoom * 100) + '%';
    minus.disabled = zoom <= 1;
    plus.disabled = zoom >= 4;
  }

  function control(action) {
    if (action === 'close') dialog.close();
    else if (action === 'plus') applyZoom(zoom * 1.5);
    else if (action === 'minus') applyZoom(zoom / 1.5);
    else if (action === 'fit') applyZoom(1, true);
  }

  image.addEventListener('load', () => {
    error.hidden = true;
    applyZoom(1, true);
  });
  image.addEventListener('error', () => {
    error.hidden = false;
    minus.disabled = true;
    plus.disabled = true;
  });
  document.addEventListener('click', event => {
    const trigger = event.target.closest('[data-action="shop-banner"]');
    if (!trigger) return;
    opener = trigger;
    zoom = 1;
    error.hidden = true;
    dialog.showModal();
    document.body.classList.add('banner-viewing');
    if (!image.getAttribute('src') || !image.naturalWidth) image.src = BANNER_SRC;
    else applyZoom(1, true);
  });
  document.addEventListener('error', event => {
    if (event.target.matches?.('.shop-banner-image')) {
      const banner = event.target.closest('.shop-banner');
      if (banner) banner.hidden = true;
    }
  }, true);
  dialog.addEventListener('click', event => {
    const button = event.target.closest('[data-banner-control]');
    if (button) control(button.dataset.bannerControl);
  });
  dialog.addEventListener('keydown', event => {
    if (event.ctrlKey || event.metaKey || event.altKey) return;
    const action = event.key === '+' || event.key === '=' ? 'plus' : event.key === '-' ? 'minus' : event.key === '0' ? 'fit' : null;
    if (action) {
      event.preventDefault();
      control(action);
    }
  });
  dialog.addEventListener('close', () => {
    document.body.classList.remove('banner-viewing');
    if (opener?.isConnected) opener.focus({preventScroll: true});
  });
  window.addEventListener('resize', () => {
    if (dialog.open) applyZoom(zoom, true);
  });
  window.addEventListener('hashchange', () => {
    if (dialog.open) dialog.close();
  });
}
