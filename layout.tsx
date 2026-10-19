import type { ReactNode } from 'react';
import './style.css';
export default function Layout({children}:{children:ReactNode}){return <html lang="it"><body><header><strong>MOBILITY PLANET</strong><span>Fleet Wash Control</span></header><main>{children}</main></body></html>}
