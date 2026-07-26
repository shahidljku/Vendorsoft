import { RequestContext } from '../services/logger';
import { Env, ApiResponse } from '../types';
import { queryCollection, setDocument } from '../services/firestore';
import { createErrorResponse } from '../authGuard';

export async function handleGetPlans(ctx: RequestContext, request: Request, env: Env): Promise<Response> {
  if (request.method !== 'GET') {
    return createErrorResponse(405, 'METHOD_NOT_ALLOWED', 'Only GET method is permitted on /api/v1/plans.');
  }

  try {
    const plans = await queryCollection(ctx, env, 'plans', [{ field: 'isActive', op: 'EQUAL', value: true }]);
    for (const p of plans) {
      if (p.planId === 'PRO_YEARLY' && p.durationDays !== 395) {
        p.durationDays = 395;
        p.description = '12 + 1 Month FREE (395 Days)';
        setDocument(ctx, env, 'plans', 'PRO_YEARLY', p).catch(() => {});
      }
    }
    const sortedPlans = plans.sort((a, b) => (b.amountPaise || 0) - (a.amountPaise || 0)); // Expensive first

    if (sortedPlans.length === 0) {
      // Fallback if not seeded
      return new Response(JSON.stringify({
        success: true,
        data: [
          { planId: 'PRO_YEARLY', planName: 'Pro Annual License', amountPaise: 149900, description: '12 + 1 Month FREE', features: ['Up to 10,000 Customers', 'WhatsApp Automation', 'Thermal Printing'] },
          { planId: 'PRO_MONTHLY', planName: 'Pro Monthly License', amountPaise: 14900, description: 'Billed monthly', features: ['Up to 1,000 Customers', 'Offline Access'] }
        ]
      }), {
        status: 200,
        headers: {
          'Content-Type': 'application/json',
          'Cache-Control': 'public, max-age=300',
          'Access-Control-Allow-Origin': '*'
        }
      });
    }

    const responsePayload: ApiResponse<any[]> = {
      success: true,
      data: sortedPlans
    };

    return new Response(JSON.stringify(responsePayload), {
      status: 200,
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': 'public, max-age=300',
        'Access-Control-Allow-Origin': '*'
      }
    });
  } catch (err: any) {
    ctx.logger.error('Failed to retrieve plans:', err);
    // Fallback if not seeded
    return new Response(JSON.stringify({
      success: true,
      data: [
        { planId: 'PRO_YEARLY', planName: 'Pro Annual License', amountPaise: 149900, description: '12 + 1 Month FREE', features: ['Up to 10,000 Customers', 'WhatsApp Automation', 'Thermal Printing'] },
        { planId: 'PRO_MONTHLY', planName: 'Pro Monthly License', amountPaise: 14900, description: 'Billed monthly', features: ['Up to 1,000 Customers', 'Offline Access'] }
      ]
    }), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  }
}
