// Edge Function: send-invoice-email
//
// Triggered by a Supabase Database Webhook on INSERT into `invoices`
// (i.e. the moment a coach confirms a payment and an invoice row is
// created). Looks up the shooter's email and sends them a real
// confirmation email via Resend (https://resend.com) — something the
// app itself cannot safely do, since a real email API key must never
// sit in client-side code where anyone could read it out of the page
// source.
//
// This file only runs when you deploy it with the Supabase CLI — see
// the deployment steps below. It does nothing on its own until then.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
// The address your emails appear to come from. Resend requires this
// domain to be verified in your Resend account before it will send —
// see step 3 in the deployment notes.
const FROM_ADDRESS = 'Range Ledger <noreply@yourdomain.com>';

Deno.serve(async (req) => {
  try {
    if (!RESEND_API_KEY || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
      return new Response(JSON.stringify({ error: 'Missing required environment secrets — see deployment notes.' }), { status: 500 });
    }

    const payload = await req.json();
    // Supabase Database Webhooks send { type, table, record, old_record, schema }
    const invoice = payload.record;
    if (!invoice || !invoice.student_id) {
      return new Response(JSON.stringify({ error: 'No invoice record in payload.' }), { status: 400 });
    }

    // Service-role client — this key has full database access and must
    // NEVER be used in the app itself, only here, server-side.
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: student, error: studentErr } = await supabase
      .from('students')
      .select('name, email')
      .eq('id', invoice.student_id)
      .single();

    if (studentErr || !student || !student.email) {
      return new Response(JSON.stringify({ error: 'Could not find a valid email for this student.' }), { status: 404 });
    }

    const amount = Number(invoice.amount).toLocaleString('en-IN');
    const html = `
      <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto;">
        <h2>Payment confirmed</h2>
        <p>Hi ${student.name},</p>
        <p>Your payment of <strong>₹${amount}</strong> has been confirmed.</p>
        <p>Invoice: <strong>${invoice.invoice_number}</strong><br/>
           Method: ${invoice.method}<br/>
           Date: ${new Date(invoice.paid_at).toLocaleDateString('en-IN')}</p>
        <p style="color: #888; font-size: 12px; margin-top: 24px;">This is an automated message from Range Ledger.</p>
      </div>
    `;

    const emailRes = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: FROM_ADDRESS,
        to: student.email,
        subject: `Payment confirmed — Invoice ${invoice.invoice_number}`,
        html,
      }),
    });

    if (!emailRes.ok) {
      const errText = await emailRes.text();
      return new Response(JSON.stringify({ error: 'Resend API error: ' + errText }), { status: 502 });
    }

    return new Response(JSON.stringify({ success: true }), { status: 200 });
  } catch (err) {
    return new Response(JSON.stringify({ error: err instanceof Error ? err.message : 'Unknown error' }), { status: 500 });
  }
});
