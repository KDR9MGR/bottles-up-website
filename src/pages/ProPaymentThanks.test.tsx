import { describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import { StaticRouter } from 'react-router-dom/server';
import { ProPaymentThanksView } from './ProPaymentThanks';

const render = (cancelled: boolean) =>
  renderToString(
    <StaticRouter location="/pay/booking-thanks">
      <ProPaymentThanksView cancelled={cancelled} />
    </StaticRouter>,
  );

describe('the page a customer lands on after paying a professional', () => {
  it('thanks them, says the money is held until the job is done and that Stripe sends the receipt', () => {
    const html = render(false);
    expect(html).toContain('data-testid="pro-thanks"');
    expect(html).toContain('Thank you');
    expect(html).toContain('held by BottlesUp until the job is done');
    expect(html).toContain('Stripe e-mails you a receipt');
    expect(html).not.toContain('Nothing was charged');
  });

  it('when they left without paying it says nothing was charged and that the booking is held for a while', () => {
    const html = render(true);
    expect(html).toContain('data-testid="pro-cancelled"');
    expect(html).toContain('Nothing was charged');
    expect(html).toContain('held until the time to pay runs out');
    expect(html).not.toContain('Thank you');
  });

  it('offers a way back to the site', () => {
    expect(render(true)).toContain('href="/"');
  });
});
