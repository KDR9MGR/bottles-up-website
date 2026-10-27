import { describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import { StaticRouter } from 'react-router-dom/server';
import { TipThanksView } from './TipThanks';

const render = (cancelled: boolean) =>
  renderToString(
    <StaticRouter location="/pay/tip-thanks">
      <TipThanksView cancelled={cancelled} />
    </StaticRouter>,
  );

describe('the page tip lands on after Stripe', () => {
  it('thanks them and says the app shows the result and Stripe e-mails a receipt', () => {
    const html = render(false);
    expect(html).toContain('data-testid="tip-thanks"');
    expect(html).toContain('Thank you');
    expect(html).toContain('Your tip is on its way to the creator');
    expect(html).toContain('Stripe e-mails you a receipt');
    expect(html).not.toContain('Nothing was charged');
  });

  it('when they left without paying it says nothing was charged', () => {
    const html = render(true);
    expect(html).toContain('data-testid="tip-cancelled"');
    expect(html).toContain('Nothing was charged');
    expect(html).toContain('You left before paying');
    expect(html).not.toContain('Thank you');
  });

  it('offers a way back to the site', () => {
    expect(render(true)).toContain('href="/"');
  });
});
