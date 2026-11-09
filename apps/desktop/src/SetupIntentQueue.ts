// Setup errors replace the controls with an error view. Already queued clicks
// must stop too, particularly file admission after a failed preference commit.
export class SetupIntentQueue {
  private tail: Promise<void> = Promise.resolve();
  private failed = false;
  private readonly onError: (reason: unknown) => void;

  constructor(onError: (reason: unknown) => void) {
    this.onError = onError;
  }

  enqueue(action: () => void | Promise<void>): Promise<void> {
    this.tail = this.tail.then(async () => {
      if (this.failed) return;
      try {
        await action();
      } catch (reason) {
        this.failed = true;
        this.onError(reason);
      }
    });
    return this.tail;
  }
}
