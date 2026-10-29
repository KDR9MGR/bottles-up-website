import { describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import { StaticRouter } from 'react-router-dom/server';
import BookingHeldNotice from './BookingHeldNotice';

// (the server renderer puts invisible comment markers between pieces of text)
const render = (email?: string) =>
  renderToString(
    <StaticRouter location="/booking/success">
      <BookingHeldNotice email={email} />
    </StaticRouter>,
  ).replace(/<!-- -->/g, '');

describe('BookingHeldNotice: a paid table that could not be kept', () => {
  it('says the payment arrived, that the table cannot be confirmed yet, and what happens next', () => {
    const html = render();
    expect(html).toContain('Payment received, but we need to check your table');
    expect(html).toContain('taken by another guest');
    expect(html).toContain('contact you');
    expect(html).toContain('pay your payment back in full');
    expect(html).toContain('do not need to pay again');
    expect(html).toContain('do not travel to the venue');
  });

  it('names the address the club will write to, when it is known', () => {
    expect(render('ada@example.com')).toContain('contact you at ada@example.com');
    expect(render()).not.toContain(' at undefined');
  });

  it('promises nothing: no confirmation, no code, no ticket', () => {
    const html = render('ada@example.com').toLowerCase();
    for (const word of ['confirmation code', 'qr', 'your table is confirmed', 'booking confirmed', 'e-ticket']) expect(html).not.toContain(word);
  });

  it('has a way back home', () => {
    expect(render()).toContain('href="/"');
  });
});
