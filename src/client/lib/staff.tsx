'use client';

// The name recorded with each staff action. There is no sign-in yet, so staff type their name once;
// this browser remembers it. It is an attribution, not authentication.
import * as React from 'react';
import {UserRound} from 'lucide-react';
import {Input} from '@/client/components/ui/input';
import {staffName} from '@/shared/actions';

const STORAGE_KEY = 'usb.staff.name';
const StaffContext = React.createContext<{name: string; setName: (v: string) => void}>({name: '', setName: () => {}});

export function StaffProvider({children}: {children: React.ReactNode}) {
  const [name, setNameState] = React.useState('');
  React.useEffect(() => {
    try {
      setNameState(window.localStorage.getItem(STORAGE_KEY) ?? '');
    } catch {
      // Storage unavailable: the name lasts for this page only.
    }
  }, []);
  const setName = React.useCallback((v: string) => {
    setNameState(v);
    try {
      window.localStorage.setItem(STORAGE_KEY, v);
    } catch {
      // Ignore.
    }
  }, []);
  return <StaffContext.Provider value={{name, setName}}>{children}</StaffContext.Provider>;
}

// {name, valid, problem}: actions are enabled only with a valid name.
export function useStaff() {
  const {name, setName} = React.useContext(StaffContext);
  const check = staffName.safeParse(name);
  return {name: name.trim(), setName, valid: check.success, problem: check.success ? null : check.error.issues[0]?.message ?? 'Enter your name'};
}

export function StaffBar({className}: {className?: string}) {
  const {name, setName, valid} = useStaff();
  const id = React.useId();
  const [draft, setDraft] = React.useState(name);
  React.useEffect(() => setDraft(name), [name]);
  return (
    <div className={`flex flex-wrap items-center gap-x-3 gap-y-2 rounded-xl border px-3 py-2 text-sm ${valid ? 'border-line bg-surface' : 'border-review-line bg-review-soft'} ${className ?? ''}`}>
      <UserRound aria-hidden className={`size-4 shrink-0 ${valid ? 'text-subtle' : 'text-review'}`} />
      <label htmlFor={id} className={valid ? 'text-muted' : 'font-medium text-review'}>
        {valid ? 'Recording actions as' : 'Enter your name to record staff actions'}
      </label>
      <Input id={id} value={draft} onChange={e => setDraft(e.target.value)} onBlur={() => setName(draft.trim())}
        onKeyDown={e => { if (e.key === 'Enter') setName(draft.trim()); }}
        placeholder="Your name" autoComplete="name" className="h-8 w-full sm:w-56" />
      <span className="w-full text-xs text-muted sm:w-auto">Saved in this browser; there is no sign-in yet.</span>
    </div>
  );
}
