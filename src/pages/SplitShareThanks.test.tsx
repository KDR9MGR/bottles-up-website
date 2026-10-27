import { describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import { StaticRouter } from 'react-router-dom/server';
import { SplitShareThanksView } from './SplitShareThanks';

const render = (cancelled: boolean) =>
  renderToString(
    <StaticRouter location="/pay/share-thanks">
      <SplitShareThanksView cancelled={cancelled} />
    </StaticRouter>,
  );

describe('the page a friend lands on after paying their share', () => {
  it('thanks them, points them back to the app and promises a receipt only from Stripe', () => {
    const html = render(false);
    expect(html).toContain('data-testid="share-thanks"');
    expect(html).toContain('Thank you');
    expect(html).toContain('BottlesUp app');
    expect(html).toContain('Stripe e-mails you a receipt');
    expect(html).not.toContain('Nothing was charged');
  });

  it('when they left without paying it says nothing was charged and that the request is still there', () => {
    const html = render(true);
    expect(html).toContain('data-testid="share-cancelled"');
    expect(html).toContain('Nothing was charged');
    expect(html).toContain('still there until the deadline');
    expect(html).not.toContain('Thank you');
  });

  it('offers a way back to the site', () => {
    expect(render(false)).toContain('href="/"');
  });
});
