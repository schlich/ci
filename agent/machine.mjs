import { setupAgent } from '@statelyai/agent';
import { initialTransition, transition } from 'xstate';
import { z } from 'zod';

// The machine chooses the next effect; only ci.nu may execute it. No model
// decides whether a topic is safe to publish or land. All facts come from the
// existing locked, checked CI operations, including the exact cleared head.
const head = z.string().min(1);
const inputSchema = z.object({ land: z.boolean(), attempts: z.number().int().min(1) });
const setup = setupAgent({
  input: inputSchema,
  context: z.object({
    land: z.boolean(), limit: z.number().int().min(1), attempt: z.number().int(),
    head: z.string(), proven: z.string(), error: z.string(),
  }),
  events: {
    PUBLISHED: z.object({ head }),
    LANDABLE: {}, QUEUED: {},
    REFRESHED: z.object({ fresh: z.boolean() }),
    CLEARED: z.object({ head }),
    ADVANCED: z.object({ head, landed: z.boolean() }),
    FAILED: z.object({ message: z.string() }),
  },
});

export const machine = setup.createMachine({
  id: 'ci-dispatch-landing',
  initial: 'publishing',
  context: ({ input }) => ({
    land: input.land, limit: input.attempts, attempt: 1,
    head: '', proven: '', error: '',
  }),
  on: {
    FAILED: ({ event }) => ({ target: '.blocked', context: { error: event.message } }),
  },
  states: {
    publishing: {
      on: {
        PUBLISHED: ({ context, event }) => ({
          target: context.land ? 'checking' : 'dispatched', context: { head: event.head },
        }),
      },
    },
    dispatched: { type: 'final' },
    checking: { on: { LANDABLE: { target: 'queueing' } } },
    queueing: { on: { QUEUED: { target: 'refreshing' } } },
    refreshing: {
      on: {
        REFRESHED: ({ context, event }) => ({
          target: event.fresh ? 'clearing' : 'republishing',
          context: { proven: context.head },
        }),
      },
    },
    republishing: {
      on: { PUBLISHED: ({ event }) => ({ target: 'proving', context: { head: event.head } }) },
    },
    proving: { on: { LANDABLE: { target: 'clearing' } } },
    clearing: {
      on: {
        CLEARED: ({ context, event }) => event.head === context.head
          ? { target: 'advancing' } : undefined,
      },
    },
    advancing: {
      on: {
        ADVANCED: ({ context, event }) => {
          if (event.head !== context.head) return undefined;
          if (event.landed) return { target: 'landed' };
          return context.attempt < context.limit
            ? { target: 'refreshing', context: { attempt: context.attempt + 1 } }
            : { target: 'exhausted' };
        },
      },
    },
    landed: { type: 'final' },
    exhausted: { type: 'final' },
    blocked: { type: 'final' },
  },
});

export function step({ input, snapshot, event }) {
  let current;
  if (snapshot) {
    current = machine.resolveState(snapshot);
    if (!event) throw new Error('A continued run requires an event.');
  } else {
    [current] = initialTransition(machine, inputSchema.parse(input));
  }
  if (event) {
    // Pure XState transitions do not validate the host's input/event data.
    const schema = eventSchemas[event.type];
    if (!schema) throw new Error(`Unknown event: ${event.type}`);
    schema.parse(event);
    if (current.status !== 'active' || !current.can(event)) {
      throw new Error(`Event ${event.type} is not legal in ${current.value}.`);
    }
    [current] = transition(machine, current, event);
  }
  return {
    snapshot: machine.getPersistedSnapshot(current), state: current.value,
    context: current.context, done: current.status === 'done',
  };
}

const eventSchemas = {
  PUBLISHED: z.object({ type: z.literal('PUBLISHED'), head }),
  LANDABLE: z.object({ type: z.literal('LANDABLE') }),
  QUEUED: z.object({ type: z.literal('QUEUED') }),
  REFRESHED: z.object({ type: z.literal('REFRESHED'), fresh: z.boolean() }),
  CLEARED: z.object({ type: z.literal('CLEARED'), head }),
  ADVANCED: z.object({ type: z.literal('ADVANCED'), head, landed: z.boolean() }),
  FAILED: z.object({ type: z.literal('FAILED'), message: z.string() }),
};
