import { useMemo } from 'react';
import { format } from 'date-fns';
import { Calendar } from '@/components/ui/calendar';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';

const toValue = (date: Date) => format(date, "yyyy-MM-dd'T'HH:mm");

const fromValue = (value: string) => {
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
};

export default function DateTimePicker({
  value,
  onChange,
  placeholder,
  disabled,
}: {
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  disabled?: boolean;
}) {
  const date = useMemo(() => (value ? fromValue(value) : null), [value]);
  const time = value?.slice(11, 16) || '20:00';

  const label = date ? format(date, 'PPP p') : (placeholder ?? 'Select date & time');

  return (
    <Popover>
      <PopoverTrigger asChild disabled={disabled}>
        <Button
          type="button"
          variant="outline"
          disabled={disabled}
          className="w-full justify-start border-gray-800 bg-gray-950 text-white disabled:opacity-60"
        >
          {label}
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-auto border-gray-800 bg-gray-950 p-3 text-white" align="start">
        <div className="space-y-3">
          <Calendar
            mode="single"
            selected={date ?? undefined}
            onSelect={(selected) => {
              if (!selected) return;
              const [h, m] = time.split(':').map((v) => parseInt(v, 10));
              const next = new Date(selected);
              next.setHours(h || 0, m || 0, 0, 0);
              onChange(toValue(next));
            }}
          />
          <Input
            type="time"
            value={time}
            onChange={(e) => {
              const nextTime = e.target.value;
              const base = date ?? new Date();
              const [h, m] = nextTime.split(':').map((v) => parseInt(v, 10));
              const next = new Date(base);
              next.setHours(h || 0, m || 0, 0, 0);
              onChange(toValue(next));
            }}
            className="border-gray-800 bg-gray-950 text-white"
          />
        </div>
      </PopoverContent>
    </Popover>
  );
}
