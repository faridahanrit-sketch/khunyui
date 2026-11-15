// Original vector illustrations: the category art is not a photograph of a sold dish.
export const THEMES = {
  made: { short: 'ตามสั่ง', name: 'อาหารตามสั่ง', note: 'จานร้อนจากกระทะ', icon: 'wok' },
  yum: { short: 'ยำ', name: 'ยำ', note: 'จานเด่นรสมือแม่', icon: 'salad' },
  som: { short: 'ส้มตำ', name: 'ส้มตำ', note: 'แซ่บถึงครก', icon: 'mortar' },
  side: { short: 'ทานคู่', name: 'ของทานคู่', note: 'อิ่มครบมื้อ', icon: 'rice' }
};

export function foodArt(type, key = type) {
  const id = 'food-' + String(key).replace(/[^a-zA-Z0-9_-]/g, '');
  const shapes = {
    made: `<path d="M117 78l30-24 8 10-32 25" fill="#754531" stroke="#4c3028" stroke-width="3"/>
      <ellipse cx="75" cy="90" rx="58" ry="27" fill="url(#${id}-pan)"/>
      <path d="M18 83c3 38 108 42 115 0" fill="#40524d" stroke="#263e36" stroke-width="3"/>
      <ellipse cx="76" cy="81" rx="56" ry="24" fill="#293d35" stroke="#a7b1a0" stroke-width="3"/>
      <g fill="#cd8853" stroke="#95562e" stroke-width="1.5"><path d="M38 75l14-9 14 7-3 13-16 5-12-8z"/><path d="M67 67l15-6 14 7-4 12-17 5-10-9z"/><path d="M91 79l14-6 12 9-5 12-16 1z"/><path d="M54 86l15-8 13 6-2 12-16 3z"/></g>
      <g fill="#639c3d" stroke="#367239" stroke-width="1.7"><path d="M29 76q0-24 26-15-5 21-26 15z"/><path d="M70 63q3-26 24-19 2 21-24 19z"/><path d="M90 83q14-25 28-12-6 23-28 12z"/><path d="M55 94q-10-21 11-24 14 20-11 24z"/></g>
      <g fill="#d74830" stroke="#9b3023" stroke-width="1.5"><path d="M42 62q23 2 30 17-24-4-30-17z"/><path d="M82 89q14-18 29-17-10 20-29 17z"/></g>
      <g stroke="#fff7dd" stroke-width="3" fill="none" stroke-linecap="round" opacity=".85"><path d="M49 45q-10-9 0-18t-1-16"/><path d="M78 36q-10-10 0-18"/><path d="M102 45q-10-8-1-17"/></g>`,
    yum: `<ellipse cx="80" cy="99" rx="57" ry="15" fill="#773b32" opacity=".17"/>
      <path d="M18 72q4 40 62 41 58-1 62-41" fill="url(#${id}-bowl)" stroke="#d8b797" stroke-width="2"/>
      <ellipse cx="80" cy="72" rx="63" ry="28" fill="#fff0d1" stroke="#fff9ec" stroke-width="4"/>
      <g stroke="#d7a460" stroke-width="3.5" fill="none" stroke-linecap="round"><path d="M30 65q28-24 54-3t44 0M30 72q25-20 55-2t41 3M39 83q21-29 50-17t26 22M48 52q-9 32 30 38M91 49q-34 30 12 40M59 52q38 8 1 42"/></g>
      <g fill="#75a552" stroke="#3f803f" stroke-width="2"><path d="M37 62q-10-21 7-24 14 16-7 24z"/><path d="M85 53q4-30 21-20 0 24-21 20z"/><path d="M109 82q7-23 23-13-3 21-23 13z"/></g>
      <g fill="#f2aa76" stroke="#cf6744" stroke-width="4"><path d="M45 78q-14-24 6-25 18 2 8 13-9-7-7 5z"/><path d="M99 70q-16-22 4-25 18 2 9 12-10-5-7 7z"/></g>
      <path d="M72 82q17-17 30-7-14 15-30 7" fill="#d94a37"/>
      <circle cx="76" cy="50" r="10" fill="#e46743"/><circle cx="76" cy="50" r="6" fill="#f8b274"/>
      <g stroke="#fff6da" stroke-width="1.6"><path d="M72 46l8 8m0-8-8 8"/></g>
      <g transform="translate(126 44)"><circle r="17" fill="#78a64b"/><circle r="13" fill="#d5e992"/><path d="M0-11v22m-11-11h22M-8-8l16 16M8-8-8 8" stroke="#f7f3b2" stroke-width="2"/></g>`,
    som: `<path d="M89 20l20-9q6-2 10 3t0 9L81 66l-17-8z" fill="url(#${id}-wood)" stroke="#75452f" stroke-width="2"/>
      <path d="M27 65h104l-18 44q-33 18-68 0z" fill="url(#${id}-wood)" stroke="#5d3a2d" stroke-width="3"/>
      <ellipse cx="79" cy="64" rx="53" ry="22" fill="#533729" stroke="#ba8a54" stroke-width="4"/>
      <g fill="none" stroke="#f6df98" stroke-width="3.5" stroke-linecap="round"><path d="M40 59l63 14M51 49l39 30M94 45L48 76M68 45l23 35M116 57L58 66"/></g>
      <g fill="#6f9a42"><path d="M33 52l27-5-17 16z"/><path d="M87 42l28-10-14 24z"/><path d="M104 66l22-8-10 19z"/></g>
      <g fill="#d65037" stroke="#8c3328" stroke-width="1.2"><path d="M62 44q26-4 35 14-27-3-35-14z"/><path d="M48 66q16-13 30-5-19 14-30 5z"/></g>
      <path d="M41 84q38 18 74 0M45 94q33 15 66 0" stroke="#cfaa72" stroke-width="2" opacity=".55" fill="none"/>
      <g transform="translate(133 93)"><circle r="18" fill="#82aa46"/><circle r="14" fill="#d8e99a"/><path d="M0-12v24m-12-12h24M-9-9l18 18M9-9-9 9" stroke="#fff2b9" stroke-width="2"/></g>`,
    side: `<path d="M35 57q45-21 90 0l-9 54q-35 15-72 0z" fill="url(#${id}-wood)" stroke="#9d6a36" stroke-width="2"/>
      <ellipse cx="80" cy="57" rx="46" ry="21" fill="#ba8c51" stroke="#e6be78" stroke-width="3"/>
      <path d="M41 52q-3-25 17-22 5-23 21-15 17-13 23 9 22-2 19 29z" fill="#fff9e7" stroke="#e6dfc5" stroke-width="2"/>
      <g fill="none" stroke="#e8dfc5" stroke-width="2" stroke-linecap="round"><path d="M55 38l6-6m8 13 5-8m7-11 5 7m15 0 4 7m-12 7 5-5M50 48l6 3m17 1 5 2"/></g>
      <g stroke="#e6bd7e" stroke-width="2" opacity=".75"><path d="M39 72h82M41 85h78M43 98h74M47 62l9 54m8-57 6 60m14-60-1 61m17-59-7 59m18-54-8 50"/></g>
      <path d="M49 15q-13-8-7-19M112 15q-9-8-3-19" stroke="#fff8df" stroke-width="3" fill="none" stroke-linecap="round"/>`
  };
  return `<svg class="food-art" viewBox="0 0 160 130" fill="none" aria-hidden="true"><defs>
    <linearGradient id="${id}-pan" x1="20" y1="62" x2="125" y2="115" gradientUnits="userSpaceOnUse"><stop stop-color="#8a9b90"/><stop offset="1" stop-color="#263e36"/></linearGradient>
    <linearGradient id="${id}-wood" x1="35" y1="25" x2="112" y2="113" gradientUnits="userSpaceOnUse"><stop stop-color="#d7a56a"/><stop offset=".45" stop-color="#9b663f"/><stop offset="1" stop-color="#654131"/></linearGradient>
    <linearGradient id="${id}-bowl" x1="80" y1="70" x2="80" y2="113" gradientUnits="userSpaceOnUse"><stop stop-color="#fff7e4"/><stop offset="1" stop-color="#dfbfa0"/></linearGradient>
  </defs><ellipse cx="80" cy="117" rx="60" ry="7" fill="#3f3327" opacity=".10"/>${shapes[type] || shapes.made}</svg>`;
}
