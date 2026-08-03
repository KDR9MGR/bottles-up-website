import { useEffect, useRef, useState } from 'react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';

export interface FloorOption {
  id: string;
  label: string;
  imageUrl: string;
}

export interface TablePlacement {
  floorId: string;
  posX: number;
  posY: number;
  width: number;
  height: number;
}

interface FloorPlanEditorProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  tableName: string;
  floors: FloorOption[];
  initialPlacement: TablePlacement | null;
  onSave: (placement: TablePlacement) => void;
  onClear: () => void;
}

const DEFAULT_BOX = { posX: 40, posY: 40, width: 20, height: 15 };
const MIN_SIZE = 4;

const clamp = (value: number, min: number, max: number) => Math.min(Math.max(value, min), max);

/**
 * A simple drag/resize box overlaid on the venue's own uploaded floor plan
 * image. Position is stored as percentages of the image's rendered size, so
 * placement stays correct no matter what size the image renders at later.
 */
const FloorPlanEditor = ({
  open,
  onOpenChange,
  tableName,
  floors,
  initialPlacement,
  onSave,
  onClear,
}: FloorPlanEditorProps) => {
  const [floorId, setFloorId] = useState('');
  const [box, setBox] = useState(DEFAULT_BOX);
  const imageRef = useRef<HTMLDivElement>(null);
  const dragState = useRef<{ mode: 'move' | 'resize'; startX: number; startY: number; box: typeof DEFAULT_BOX } | null>(null);

  useEffect(() => {
    if (!open) return;
    setFloorId(initialPlacement?.floorId ?? floors[0]?.id ?? '');
    setBox(
      initialPlacement
        ? { posX: initialPlacement.posX, posY: initialPlacement.posY, width: initialPlacement.width, height: initialPlacement.height }
        : DEFAULT_BOX,
    );
  }, [open, initialPlacement, floors]);

  useEffect(() => {
    const handleMove = (e: MouseEvent) => {
      const state = dragState.current;
      const rect = imageRef.current?.getBoundingClientRect();
      if (!state || !rect) return;

      const deltaXPct = ((e.clientX - state.startX) / rect.width) * 100;
      const deltaYPct = ((e.clientY - state.startY) / rect.height) * 100;

      if (state.mode === 'move') {
        setBox({
          ...state.box,
          posX: clamp(state.box.posX + deltaXPct, 0, 100 - state.box.width),
          posY: clamp(state.box.posY + deltaYPct, 0, 100 - state.box.height),
        });
      } else {
        setBox({
          ...state.box,
          width: clamp(state.box.width + deltaXPct, MIN_SIZE, 100 - state.box.posX),
          height: clamp(state.box.height + deltaYPct, MIN_SIZE, 100 - state.box.posY),
        });
      }
    };

    const handleUp = () => {
      dragState.current = null;
    };

    window.addEventListener('mousemove', handleMove);
    window.addEventListener('mouseup', handleUp);
    return () => {
      window.removeEventListener('mousemove', handleMove);
      window.removeEventListener('mouseup', handleUp);
    };
  }, []);

  const startDrag = (mode: 'move' | 'resize') => (e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    dragState.current = { mode, startX: e.clientX, startY: e.clientY, box };
  };

  const selectedFloor = floors.find((f) => f.id === floorId);

  const handleSave = () => {
    if (!floorId) return;
    onSave({ floorId, posX: box.posX, posY: box.posY, width: box.width, height: box.height });
    onOpenChange(false);
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-2xl border-gray-800 bg-gray-950">
        <DialogHeader>
          <DialogTitle className="text-white">Place "{tableName}" on the floor plan</DialogTitle>
        </DialogHeader>

        {floors.length === 0 ? (
          <p className="text-sm text-gray-400">
            Upload at least one floor image in the Floors section below first.
          </p>
        ) : (
          <div className="space-y-4">
            <div className="space-y-2">
              <Label>Floor</Label>
              <Select value={floorId} onValueChange={setFloorId}>
                <SelectTrigger>
                  <SelectValue placeholder="Select a floor" />
                </SelectTrigger>
                <SelectContent>
                  {floors.map((f) => (
                    <SelectItem key={f.id} value={f.id}>
                      {f.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            {selectedFloor && (
              <div>
                <p className="mb-2 text-xs text-gray-500">
                  Drag the box onto the table, drag its corner handle to resize.
                </p>
                <div ref={imageRef} className="relative w-full select-none overflow-hidden rounded-lg border border-gray-800">
                  <img src={selectedFloor.imageUrl} alt={selectedFloor.label} className="pointer-events-none block w-full" draggable={false} />
                  <div
                    onMouseDown={startDrag('move')}
                    className="absolute cursor-move border-2 border-orange-500 bg-orange-500/25"
                    style={{
                      left: `${box.posX}%`,
                      top: `${box.posY}%`,
                      width: `${box.width}%`,
                      height: `${box.height}%`,
                    }}
                  >
                    <div
                      onMouseDown={startDrag('resize')}
                      className="absolute -bottom-1.5 -right-1.5 h-3 w-3 cursor-nwse-resize rounded-full border border-black bg-orange-500"
                    />
                  </div>
                </div>
              </div>
            )}
          </div>
        )}

        <DialogFooter className="sm:justify-between">
          {initialPlacement ? (
            <Button
              type="button"
              variant="ghost"
              className="text-red-400 hover:text-red-300"
              onClick={() => {
                onClear();
                onOpenChange(false);
              }}
            >
              Remove from floor plan
            </Button>
          ) : (
            <span />
          )}
          <div className="flex gap-2">
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button
              type="button"
              onClick={handleSave}
              disabled={!floorId}
              className="bg-gradient-orange text-black font-bold hover:opacity-90"
            >
              Save Placement
            </Button>
          </div>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

export default FloorPlanEditor;
