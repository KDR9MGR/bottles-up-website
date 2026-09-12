import { useEffect, useRef } from 'react';

/**
 * Soft glow that follows the cursor across the whole page. Mounted once,
 * site-wide. Desktop/mouse only — pointer-follow has no meaning on touch,
 * and `prefers-reduced-motion` users get it hidden entirely via CSS.
 */
const Spotlight = () => {
  const ref = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (window.matchMedia('(pointer: coarse)').matches) return;
    const el = ref.current;
    if (!el) return;

    const move = (e: PointerEvent) => {
      if (e.pointerType !== 'mouse') return;
      el.style.opacity = '1';
      el.style.setProperty('--sx', `${e.clientX}px`);
      el.style.setProperty('--sy', `${e.clientY}px`);
    };
    const leave = () => {
      el.style.opacity = '0';
    };

    window.addEventListener('pointermove', move);
    window.addEventListener('pointerleave', leave);
    return () => {
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerleave', leave);
    };
  }, []);

  return (
    <div
      ref={ref}
      aria-hidden="true"
      className="spotlight pointer-events-none fixed inset-0 z-[5] opacity-0 transition-opacity duration-500 motion-reduce:hidden"
    />
  );
};

export default Spotlight;
