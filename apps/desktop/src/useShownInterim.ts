import { useLayoutEffect, useRef, useState } from 'react';
import { interimStep } from './previewText';

export function useShownInterim(target: string, generation: number): string {
  const [shown, setShown] = useState(target);
  const current = useRef({ text: target, generation });
  useLayoutEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    if (current.current.generation !== generation) current.current = { text: '', generation };
    const step = () => {
      current.current.text = interimStep(current.current.text, target);
      setShown(current.current.text);
      if (current.current.text.normalize('NFC') !== target.normalize('NFC')) timer = setTimeout(step, 24);
    };
    step();
    return () => clearTimeout(timer);
  }, [target, generation]);
  return shown;
}
