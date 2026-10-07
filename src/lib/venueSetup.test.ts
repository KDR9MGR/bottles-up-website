import { describe, expect, it } from 'vitest';
import { orderSteps, statusLabel, stepDescription, stepLabel, summarizeSetup, type SetupStep } from './venueSetup';

const step = (name: string, status: SetupStep['status'], required = true, detail: string | null = null): SetupStep => ({
  step: name, status, required, detail,
});

describe('summarizeSetup', () => {
  const all = [
    step('profile', 'todo'),
    step('floor_plan', 'todo'),
    step('tables', 'todo'),
    step('bottles', 'todo'),
    step('booking_rules', 'todo'),
    step('team', 'todo', false),
    step('payments', 'unavailable', false),
    step('notifications', 'unavailable', false),
  ];

  it('a new venue is 0% ready with the first required step as the next action', () => {
    const s = summarizeSetup(all);
    expect(s).toMatchObject({ requiredTotal: 5, requiredDone: 0, requiredTodo: 5, percent: 0, ready: false });
    expect(s.nextStep?.step).toBe('profile');
  });

  it('counts only required steps; optional and unavailable ones never inflate or block readiness', () => {
    const done = all.map((s) => (s.required ? { ...s, status: 'done' as const } : s));
    const s = summarizeSetup(done);
    expect(s).toMatchObject({ requiredDone: 5, percent: 100, ready: true, nextStep: null });
  });

  it('rounds the percentage to a whole number', () => {
    const s = summarizeSetup([step('profile', 'done'), step('floor_plan', 'todo'), step('tables', 'todo')]);
    expect(s.percent).toBe(33);
  });

  it('points at the first to-do step in the checklist order, not the order received', () => {
    const shuffled = [step('booking_rules', 'todo'), step('profile', 'done'), step('tables', 'todo'), step('floor_plan', 'done')];
    expect(summarizeSetup(shuffled).nextStep?.step).toBe('tables');
  });

  it('measuring nothing is not "100% ready"', () => {
    expect(summarizeSetup([])).toMatchObject({ requiredTotal: 0, percent: 0, ready: false, nextStep: null });
    expect(summarizeSetup([step('payments', 'unavailable', false)]).ready).toBe(false);
  });
});

describe('wording and order', () => {
  it('orders steps as the brief lists them and keeps unknown ones at the end', () => {
    const out = orderSteps([step('notifications', 'unavailable', false), step('new_thing', 'todo'), step('profile', 'done'), step('team', 'todo', false)]);
    expect(out.map((s) => s.step)).toEqual(['profile', 'team', 'notifications', 'new_thing']);
  });

  it('labels every step the database reports', () => {
    for (const s of ['profile', 'floor_plan', 'tables', 'bottles', 'booking_rules', 'payments', 'team', 'notifications']) {
      expect(stepLabel(s)).not.toBe(s);
      expect(stepDescription(s).length).toBeGreaterThan(5);
    }
  });

  it('shows an unknown step by name instead of hiding it', () => {
    expect(stepLabel('fire_exits')).toBe('fire exits');
    expect(stepDescription('fire_exits')).toBe('');
  });

  it('never shows an unavailable step as done or pending', () => {
    expect(statusLabel('unavailable')).toBe('Coming soon');
    expect(statusLabel('done')).toBe('Done');
    expect(statusLabel('todo')).toBe('To do');
  });
});
