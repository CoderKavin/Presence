// notify-unlock — fires every 5 minutes via pg_cron.
//
// Manual review flow:
//   1. register_signup inserts a row into unlock_notifications when a school
//      crosses 30 signups.
//   2. This function picks up rows where emailed_to_admin_at IS NULL, sends
//      the admin an email via Resend with school name, count, and the full
//      list of phone numbers + timestamps, and marks the row as emailed.
//   3. The admin reviews the email — checking that the signups don't all
//      come from one IP, weren't created in a 60-second burst, look like
//      real numbers, etc. — and only then manually decides to text the list.
//      (This function does NOT send the user-facing SMS. That's a deliberate
//      manual step.)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL    = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE    = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ADMIN_EMAIL     = Deno.env.get("ADMIN_EMAIL")!;
const RESEND_API_KEY  = Deno.env.get("RESEND_API_KEY")!;
const RESEND_FROM     = Deno.env.get("RESEND_FROM_EMAIL") ?? "Presence <onboarding@resend.dev>";

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE);

interface PendingRow {
  id: string;
  school_id: string;
  reached_at: string;
}

interface School {
  name: string;
  signup_count: number;
}

interface Signup {
  phone: string;
  country_code: string;
  position_in_school: number;
  created_at: string;
}

async function sendEmail(school: School, row: PendingRow, signups: Signup[]) {
  const subject = `Presence: ${school.name} just hit 30 signups`;
  const lines = signups.map(
    (s) => `  ${String(s.position_in_school).padStart(2, " ")}.  ${s.phone}   (${s.country_code})   ${s.created_at}`,
  ).join("\n");

  const text = [
    `${school.name} hit ${school.signup_count} signups.`,
    `Threshold reached at ${row.reached_at}.`,
    ``,
    `Signups in order:`,
    lines,
    ``,
    `Review them in Supabase Studio (Tables → signups, filter school_id = ${row.school_id})`,
    `before texting. Look for: phones from one IP/ASN, bursts in <60s, fake-looking`,
    `numbers, identical user-agents.`,
    ``,
    `If they look real, text the list manually. Then mark unlock_notifications.manual_reviewed_at`,
    `and schools.unlock_notified = true.`,
  ].join("\n");

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${RESEND_API_KEY}`,
    },
    body: JSON.stringify({ from: RESEND_FROM, to: ADMIN_EMAIL, subject, text }),
  });

  if (!res.ok) {
    throw new Error(`resend ${res.status}: ${await res.text()}`);
  }
}

Deno.serve(async () => {
  const { data: pending, error } = await supabase
    .from("unlock_notifications")
    .select("id, school_id, reached_at")
    .is("emailed_to_admin_at", null);

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const sent: string[] = [];
  const failed: { id: string; error: string }[] = [];

  for (const row of (pending ?? []) as PendingRow[]) {
    try {
      const { data: school, error: schoolErr } = await supabase
        .from("schools")
        .select("name, signup_count")
        .eq("id", row.school_id)
        .single();
      if (schoolErr || !school) throw new Error(schoolErr?.message ?? "school missing");

      const { data: signups, error: signupsErr } = await supabase
        .from("signups")
        .select("phone, country_code, position_in_school, created_at")
        .eq("school_id", row.school_id)
        .order("position_in_school", { ascending: true });
      if (signupsErr) throw new Error(signupsErr.message);

      await sendEmail(school as School, row, (signups ?? []) as Signup[]);

      const { error: updateErr } = await supabase
        .from("unlock_notifications")
        .update({ emailed_to_admin_at: new Date().toISOString() })
        .eq("id", row.id);
      if (updateErr) throw new Error(updateErr.message);

      sent.push(row.id);
    } catch (e) {
      failed.push({ id: row.id, error: e instanceof Error ? e.message : String(e) });
    }
  }

  return new Response(JSON.stringify({ checked: pending?.length ?? 0, sent: sent.length, failed }), {
    status: failed.length === (pending?.length ?? 0) && (pending?.length ?? 0) > 0 ? 500 : 200,
    headers: { "Content-Type": "application/json" },
  });
});
