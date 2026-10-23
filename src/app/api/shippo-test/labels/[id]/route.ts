import {connection, errorBody, queryJson} from '@/server/db';
import {readLabelFile} from '@/server/shippo/service';

export const dynamic = 'force-dynamic';

// Serves a stored TEST label for preview or download (never printed by the app, never re-purchased).
export async function GET(req: Request, ctx: {params: Promise<{id: string}>}) {
  const {id} = await ctx.params;
  if (!/^\d{1,12}$/.test(id)) return Response.json({error: 'Invalid label id'}, {status: 400});
  try {
    const row = await queryJson<{file_name: string; content_type: string} | null>(connection('booking'),
      `(SELECT json_build_object('file_name', file_name, 'content_type', content_type) FROM us_booking.shippo_test_label WHERE id = ${id})`);
    const bytes = row ? readLabelFile(row.file_name) : null;
    if (!row || !bytes) return Response.json({error: 'Test label not found'}, {status: 404});
    const inline = new URL(req.url).searchParams.get('inline') === '1' && row.content_type === 'application/pdf';
    return new Response(new Uint8Array(bytes), {
      headers: {
        'Content-Type': row.content_type === 'application/pdf' ? 'application/pdf' : 'application/octet-stream',
        'Content-Disposition': `${inline ? 'inline' : 'attachment'}; filename="${row.file_name}"`,
        'X-Content-Type-Options': 'nosniff',
        'Cache-Control': 'no-store',
      },
    });
  } catch (e) {
    return Response.json(errorBody(e), {status: 503});
  }
}
