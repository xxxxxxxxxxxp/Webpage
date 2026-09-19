import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const response = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (request.method !== 'POST') return response({ success: false, error: 'Method not allowed.' }, 405)

  try {
    const { email, password, adminPasscode } = await request.json()
    const normalizedEmail = typeof email === 'string' ? email.trim().toLowerCase() : ''
    if (!/^\S+@\S+\.\S+$/.test(normalizedEmail) || typeof password !== 'string' || !password || typeof adminPasscode !== 'string' || !adminPasscode) {
      return response({ success: false, error: 'Enter a valid email, password, and administrator passcode.' }, 400)
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      { auth: { persistSession: false, autoRefreshToken: false } },
    )

    // This service-role-only RPC reads and compares the private hash server-side without auth.uid().
    const { data: verified, error: verificationError } = await supabase.rpc('verify_admin_registration_passcode', { passcode: adminPasscode })
    if (verificationError) {
      console.error('[register-admin] Passcode verification failed:', verificationError.message)
      return response({ success: false, error: 'Administrator registration is unavailable.' }, 500)
    }
    if (verified !== true) return response({ success: false, error: 'Incorrect administrator passcode.' }, 403)

    const displayName = normalizedEmail.split('@')[0].slice(0, 120)
    // Verification completed before this privileged call. Do not set email_confirm true: this preserves confirmation.
    const { data: created, error: createError } = await supabase.auth.admin.createUser({
      email: normalizedEmail,
      password,
      email_confirm: true,
      user_metadata: { display_name: displayName },
    })
    if (createError || !created.user) {
      const message = createError?.message?.toLowerCase().includes('already') ? 'An account with this email already exists.' : 'Administrator account could not be created.'
      if (createError) console.error('[register-admin] Auth user creation failed:', createError.message)
      return response({ success: false, error: message }, createError?.message?.toLowerCase().includes('already') ? 409 : 500)
    }

    const { error: profileError } = await supabase.from('profiles').insert({
      id: created.user.id,
      display_name: displayName,
      role: 'admin',
      current_academic_year: 1,
    })
    if (profileError) {
      console.error('[register-admin] Profile creation failed:', profileError.message)
      const { error: cleanupError } = await supabase.auth.admin.deleteUser(created.user.id)
      if (cleanupError) console.error('[register-admin] Auth-user cleanup failed:', cleanupError.message)
      return response({ success: false, error: cleanupError ? 'Administrator profile could not be created; please contact support.' : 'Administrator account could not be created.' }, 500)
    }

    return response({ success: true, confirmationRequired: true, message: 'Administrator account created. Confirm the account email before signing in.' })
  } catch (error) {
    console.error('[register-admin] Unexpected error:', error instanceof Error ? error.message : 'unknown error')
    return response({ success: false, error: 'Administrator registration could not be completed.' }, 500)
  }
})
