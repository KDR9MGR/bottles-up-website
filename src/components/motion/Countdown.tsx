import { useEffect, useState } from 'react';

/** Live countdown to a real target date/time. Renders nothing once passed. */
const Countdown = ({ target }: { target: string }) => {
  const [left, setLeft] = useState<{ d: number; h: number; m: number; s: number } | null>(null);

  useEffect(() => {
    const end = new Date(target).getTime();
    const tick = () => {
      const ms = end - Date.now();
      if (ms <= 0) {
        setLeft(null);
        return;
      }
      setLeft({
        d: Math.floor(ms / 86400000),
        h: Math.floor(ms / 3600000) % 24,
        m: Math.floor(ms / 60000) % 60,
        s: Math.floor(ms / 1000) % 60,
      });
    };
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [target]);

  if (!left) return null;

  const cells = [
    { v: left.d, l: 'Days' },
    { v: left.h, l: 'Hrs' },
    { v: left.m, l: 'Min' },
    { v: left.s, l: 'Sec' },
  ];

  return (
    <div className="inline-flex items-center gap-2">
      {cells.map((c) => (
        <div
          key={c.l}
          className="min-w-[3.4rem] rounded-xl border border-white/10 bg-white/5 px-2 py-2 text-center backdrop-blur-xl"
        >
          <div className="font-display text-lg font-extrabold tabular-nums text-orange-500">
            {String(c.v).padStart(2, '0')}
          </div>
          <div className="text-[10px] font-bold uppercase tracking-widest text-gray-500">{c.l}</div>
        </div>
      ))}
    </div>
  );
};

export default Countdown;
