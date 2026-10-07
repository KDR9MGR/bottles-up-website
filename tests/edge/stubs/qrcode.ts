// Stand-in for `npm:qrcode@1.5.3`. Returns a recognisable string instead of an image.
export default {
  toDataURL: async (text: string) => `data:image/png;base64,QR(${text})`,
};
