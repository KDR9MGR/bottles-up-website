import { Navigate, useLocation } from 'react-router-dom';
import { useDoorAuth } from './useDoorAuth';

const RequireDoorAuth = ({ children }: { children: React.ReactNode }) => {
  const { session, isDoorStaff, loading } = useDoorAuth();
  const location = useLocation();

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-black text-gray-400">
        Loading...
      </div>
    );
  }

  if (!session || !isDoorStaff) {
    return <Navigate to="/door/login" state={{ from: location }} replace />;
  }

  return <>{children}</>;
};

export default RequireDoorAuth;
