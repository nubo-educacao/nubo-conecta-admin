import { supabase } from "@/integrations/supabase/client";

export interface DateRange {
  from?: Date;
  to?: Date;
}

export interface PowerUser {
  userId: string;
  userName: string;
  userPhone: string;
  accessCount: number;
}

export interface DashboardStats {
  totalRegistered: number;
  activeUsers: number;
  activeUsersWithMessages: number;
  catalogUsers: number;
  activeUsersChange: number;
  catalogUsersChange: number;
  totalMessages: number;
  messagesChange: number;
  totalFavorites: number;
  favoritesChange: number;
  errorsToday: number;
  errorsChange: number;
  powerUsers: number;
  powerUsersChange: number;
  powerUsersList: PowerUser[];
}

export interface ActivityData {
  dia: string;
  mensagens: number;
  usuarios: number;
}

export interface CourseInterest {
  name: string;
  searches: number;
  buscas?: number;
}

export interface FunnelStep {
  etapa: string;
  valor: number;
  label?: string;
  value?: number;
  color?: string;
  description?: string;
  user_ids?: string[];
}

export interface UserPreference {
  name: string;
  value: number;
  color?: string;
}

export interface ErrorLog {
  id: string;
  type: "error" | "warning" | "info";
  message: string;
  count: number;
  time: string;
  timestamp?: string;
  error_type?: string;
  errorType?: string;
  resolved?: boolean;
  recoveryAttempted?: boolean;
  stackTrace?: string;
  endpoint?: string;
  metadata?: Record<string, unknown>;
  sessionId?: string;
  userId?: string;
  createdAt?: string;
}

export interface TopUser {
  id: string;
  name: string;
  messages: number;
  favorites: number;
  score: number;
  sessions: number;
  user_id?: string;
  full_name?: string;
  message_count?: number;
  favorites_count?: number;
}

export interface LocationData {
  name: string;
  count: number;
  city?: string;
  state?: string;
}

// Fetch dashboard statistics via Edge Function
export async function fetchDashboardStats(dateRange?: DateRange): Promise<DashboardStats> {
  const { data, error } = await supabase.functions.invoke('analytics-stats', {
    body: { dateRange },
  });

  if (error) {
    console.error('Error fetching dashboard stats:', error);
    throw error;
  }

  return data as DashboardStats;
}

// Fetch activity data (last 7 days)
export async function fetchActivityData(): Promise<ActivityData[]> {
  const { data, error } = await supabase.functions.invoke('analytics-activity');

  if (error) {
    console.error('Error fetching activity data:', error);
    throw error;
  }

  return data as ActivityData[];
}

// Fetch top courses by interest
export async function fetchTopCourses(): Promise<CourseInterest[]> {
  const response = await supabase.functions.invoke('analytics-rankings', {
    body: { type: 'courses' },
  });

  if (response.error) {
    console.error('Error fetching top courses:', response.error);
    throw response.error;
  }

  return response.data as CourseInterest[];
}

// Fetch funnel data
export async function fetchFunnelData(): Promise<FunnelStep[]> {
  const { data, error } = await supabase.functions.invoke('analytics-funnel');

  if (error) {
    console.error('Error fetching funnel data:', error);
    throw error;
  }

  return data as FunnelStep[];
}

// Fetch user preferences distribution
export async function fetchUserPreferences(): Promise<UserPreference[]> {
  const response = await supabase.functions.invoke('analytics-rankings', {
    body: { type: 'preferences' },
  });

  if (response.error) {
    console.error('Error fetching user preferences:', response.error);
    throw response.error;
  }

  return response.data as UserPreference[];
}

// Fetch error logs
export async function fetchErrorLogs(filters?: {
  type?: string;
  status?: string;
  limit?: number;
}): Promise<ErrorLog[]> {
  const { data, error } = await supabase.functions.invoke('analytics-errors', {
    body: filters || {},
  });

  if (error) {
    console.error('Error fetching error logs:', error);
    throw error;
  }

  return data as ErrorLog[];
}

// Fetch top engaged users
export async function fetchTopUsers(): Promise<TopUser[]> {
  const response = await supabase.functions.invoke('analytics-rankings', {
    body: { type: 'users' },
  });

  if (response.error) {
    console.error('Error fetching top users:', response.error);
    throw response.error;
  }

  return response.data as TopUser[];
}

// Fetch location data
export async function fetchLocationData(): Promise<LocationData[]> {
  const response = await supabase.functions.invoke('analytics-rankings', {
    body: { type: 'locations' },
  });

  if (response.error) {
    console.error('Error fetching location data:', response.error);
    throw response.error;
  }

  return response.data as LocationData[];
}

// Opportunity Types interfaces - Updated for user behavior focus
export interface SavedOpportunity {
  type: string;
  count: number;
  uniqueUsers: number;
}

export interface ProgramPreference {
  name: string;
  count: number;
  percentage: number;
}

export interface ModalityBreakdown {
  name: string;
  count: number;
}

export interface ConversionInsight {
  interestedInSisu: number;
  savedSisu: number;
  interestedInProuni: number;
  savedProuni: number;
}

export interface OpportunityTypesData {
  savedOpportunities: {
    byType: SavedOpportunity[];
    withVagasOciosas: number;
    total: number;
  };
  programPreferences: ProgramPreference[];
  vagasOciosas: {
    total: number;
    byModality: ModalityBreakdown[];
  };
  conversionInsight: ConversionInsight;
}

// Fetch opportunity types data
export async function fetchOpportunityTypes(): Promise<OpportunityTypesData> {
  const { data, error } = await supabase.functions.invoke('analytics-opportunities');

  if (error) {
    console.error('Error fetching opportunity types:', error);
    throw error;
  }

  return data as OpportunityTypesData;
}
