import { describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import { StaticRouter } from 'react-router-dom/server';
import { SubscriptionThanksView } from './SubscriptionThanks';

const render = (cancelled: boolean) =>
  renderToString(
    <StaticRouter location="/pay/subscription-thanks">
      <SubscriptionThanksView cancelled={cancelled} />
    </StaticRouter>,
  );

describe('the page subscription lands on after Stripe', () => {
  it('thanks them and says the app shows the result and Stripe e-mails a receipt', () => {
    const html = render(false);
    expect(html).toContain('data-testid="subscription-thanks"');
    expect(html).toContain('Thank you');
    expect(html).toContain('Your subscription is being set up');
    expect(html).toContain('Stripe e-mails you a receipt');
    expect(html).not.toContain('Nothing was charged');
  });

  it('when they left without paying it says nothing was charged', () => {
    const html = render(true);
    expect(html).toContain('data-testid="subscription-cancelled"');
    expect(html).toContain('Nothing was charged');
    expect(html).toContain('You left before subscribing');
    expect(html).not.toContain('Thank you');
  });

  it('offers a way back to the site', () => {
    expect(render(true)).toContain('href="/"');
  });
});
