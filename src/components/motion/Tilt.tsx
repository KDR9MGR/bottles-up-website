import { useRef, type ReactNode } from 'react';

/** Subtle pointer-follow 3D tilt for cards. Desktop only. */
const Tilt = ({ children, className = '' }: { children: ReactNode; className?: string }) => {
  const ref = useRef<HTMLDivElement | null>(null);

  return (
    <div
      ref={ref}
      className={`[transform:perspective(900px)_rotateX(var(--rx,0deg))_rotateY(var(--ry,0deg))] transition-transform duration-300 ease-out motion-reduce:!transform-none ${className}`}
      onPointerMove={(e) => {
        if (e.pointerType !== 'mouse') return;
        const el = ref.current;
        if (!el) return;
        const r = el.getBoundingClientRect();
        const x = (e.clientX - r.left) / r.width;
        const y = (e.clientY - r.top) / r.height;
        el.style.setProperty('--rx', `${(0.5 - y) * 6}deg`);
        el.style.setProperty('--ry', `${(x - 0.5) * 8}deg`);
      }}
      onPointerLeave={() => {
        const el = ref.current;
        if (!el) return;
        el.style.setProperty('--rx', '0deg');
        el.style.setProperty('--ry', '0deg');
      }}
    >
      {children}
    </div>
  );
};

export default Tilt;
