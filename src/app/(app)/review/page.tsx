import type {Metadata} from 'next';
import {OrderReview} from '@/client/components/order-review';

export const metadata: Metadata = {title: 'Order Review · US Booking'};

export default function ReviewPage() {
  return <OrderReview />;
}
