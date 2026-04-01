import React, { useState } from "react";
import Sidebar from "./Sidebar";
import { useAuth } from "@/context/AuthContext";
import { Navigate, Outlet } from "react-router-dom";
import { Sheet, SheetContent, SheetTrigger } from "@/components/ui/sheet";
import { Button } from "@/components/ui/button";
import { Menu } from "lucide-react";

export default function AdminLayout() {
    const { session, loading } = useAuth();
    const [isMobileOpen, setIsMobileOpen] = useState(false);

    if (loading) {
        return (
            <div className="flex h-screen w-screen items-center justify-center">
                <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary"></div>
            </div>
        );
    }

    if (!session) {
        return <Navigate to="/login" replace />;
    }

    return (
        <div className="flex h-screen w-screen bg-background overflow-hidden">
            {/* Desktop Sidebar */}
            <div className="hidden md:flex h-full">
                <Sidebar />
            </div>

            {/* Mobile Sidebar */}
            <Sheet open={isMobileOpen} onOpenChange={setIsMobileOpen}>
                <SheetContent side="left" className="p-0 w-64">
                    <Sidebar />
                </SheetContent>
            </Sheet>

            <div className="flex-1 flex flex-col min-w-0 overflow-hidden">
                {/* Top Header for Mobile */}
                <header className="md:hidden flex h-16 items-center justify-between px-4 border-b shrink-0">
                    <span className="font-bold text-lg">Nubo Admin</span>
                    <Button
                        variant="ghost"
                        size="icon"
                        onClick={() => setIsMobileOpen(true)}
                    >
                        <Menu className="h-6 w-6" />
                    </Button>
                </header>

                <main className="flex-1 overflow-auto p-4 md:p-8">
                    <Outlet />
                </main>
            </div>
        </div>
    );
}
