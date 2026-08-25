const STEPS = [
  { n: '01', title: 'Open', description: 'See who’s busy right now, block by block.' },
  { n: '02', title: 'Pick', description: 'Table, booth or ticket - real prices, no calls.' },
  { n: '03', title: 'Book', description: 'Deposit held, host confirms in minutes.' },
  { n: '04', title: 'Walk in', description: 'Show the pass at the door. That’s it.' },
];

const FourTapsToTheTable = () => {
  return (
    <section id="how-it-works" className="container mx-auto px-4 py-14 lg:px-6">
      <h2 className="mb-8 text-2xl font-bold text-white">Four taps to the table</h2>
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {STEPS.map((step) => (
          <div key={step.n} className="rounded-xl border border-gray-800 p-5">
            <div className="mb-3 h-px w-6 bg-primary" />
            <div className="mb-1 text-sm font-bold text-primary">{step.n}</div>
            <div className="mb-1.5 font-semibold text-white">{step.title}</div>
            <p className="text-sm text-gray-400">{step.description}</p>
          </div>
        ))}
      </div>
    </section>
  );
};

export default FourTapsToTheTable;
