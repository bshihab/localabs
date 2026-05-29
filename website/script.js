// Localabs marketing site — tiny enhancement layer.
//
// Everything semantic is in the HTML (nav links, anchor scrolling,
// <details> for FAQ). This script just adds:
//   1. Subtle header elevation when the page is scrolled away from
//      the top, mirroring Apple's docs and Claude.ai header behavior.
//   2. A close-on-open-sibling toggle for FAQ items so only one
//      <details> is expanded at a time. The HTML still works
//      without JS — this is purely UX polish.

(() => {
    const header = document.querySelector('.site-header');
    if (header) {
        const updateHeader = () => {
            if (window.scrollY > 8) {
                header.classList.add('is-scrolled');
            } else {
                header.classList.remove('is-scrolled');
            }
        };
        updateHeader();
        window.addEventListener('scroll', updateHeader, { passive: true });
    }

    // Single-open FAQ accordion. Plain <details> elements work fine
    // independently; this just collapses siblings when a new one opens
    // so the page doesn't grow uncomfortably tall.
    const faqGroup = document.querySelector('.faq-list');
    if (faqGroup) {
        const items = Array.from(faqGroup.querySelectorAll('details'));
        items.forEach((item) => {
            item.addEventListener('toggle', () => {
                if (!item.open) return;
                items.forEach((other) => {
                    if (other !== item && other.open) {
                        other.open = false;
                    }
                });
            });
        });
    }
})();
