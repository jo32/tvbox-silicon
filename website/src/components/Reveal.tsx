import type { ElementType, ReactNode } from "react";
import { useReveal } from "../hooks/useReveal";

interface Props {
  as?: ElementType;
  className?: string;
  id?: string;
  children: ReactNode;
}

/** Wrapper that fades its content up when it scrolls into view. */
export function Reveal({ as: Tag = "div", className, id, children }: Props) {
  const ref = useReveal<HTMLElement>();
  return (
    <Tag ref={ref} id={id} className={className ? `reveal ${className}` : "reveal"}>
      {children}
    </Tag>
  );
}
