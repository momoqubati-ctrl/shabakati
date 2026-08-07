import { PurchaseSaga } from "./purchaseSaga.ts";

export class PurchaseService {
  /**
   * Translates the command into a UBTR and triggers the Saga.
   */
  async executePurchase(payload: any) {
    const ubtr = this.generateUBTR();
    
    // In a real implementation, this would trigger the RPC transaction boundary
    const saga = new PurchaseSaga();
    await saga.start(ubtr, payload);

    return {
      ubtr: ubtr,
      status: "PROCESSING"
    };
  }

  private generateUBTR(): string {
    const date = new Date().toISOString().replace(/[-T:.Z]/g, '').slice(0, 14);
    const random = Math.floor(Math.random() * 1000).toString().padStart(3, '0');
    return `${date}${random}`;
  }
}
