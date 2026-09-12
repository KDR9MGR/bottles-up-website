import { useRef, type ReactNode } from 'react';

/** Button/link wrapper that leans gently towards the cursor. Desktop only —
 *  pointer-follow has no meaning on touch, so it's a no-op there. */
const Magnetic = ({ children, className = '' }: { children: ReactNode; className?: string }) => {
  const ref = useRef<HTMLSpanElement | null>(null);

  return (
    <span
      ref={ref}
      className={`inline-block transition-transform duration-200 ease-out motion-reduce:transition-none ${className}`}
      onPointerMove={(e) => {
        if (e.pointerType !== 'mouse') return;
        const el = ref.current;
        if (!el) return;
        const r = el.getBoundingClientRect();
        const x = e.clientX - r.left - r.width / 2;
        const y = e.clientY - r.top - r.height / 2;
        el.style.transform = `translate(${x * 0.18}px, ${y * 0.28}px)`;
      }}
      onPointerLeave={() => {
        if (ref.current) ref.current.style.transform = 'translate(0,0)';
      }}
    >
      {children}
    </span>
  );
};

export default Magnetic;
